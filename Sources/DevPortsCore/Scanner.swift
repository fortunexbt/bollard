import Foundation
import ProcessBridge

public enum Native {
  public static func read(_ pid: Int32) -> Proc? {
    var raw = DPProcess()
    guard dp_read(pid, &raw) == 1 else { return nil }
    func string<T>(_ value: inout T) -> String {
      withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
      }
    }
    let argv = [CChar](unsafeUninitializedCapacity: 262144) { buffer, initializedCount in
      initializedCount = max(0, Int(dp_args(pid, buffer.baseAddress!, Int32(buffer.count))))
    }
    let args = argv.split(separator: 0).map {
      String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    var p = Proc(
      pid: pid, parent: raw.ppid, start: raw.start, unique: raw.unique, version: raw.version,
      parentUnique: raw.parent_unique, uid: raw.uid, path: string(&raw.path), cwd: string(&raw.cwd),
      args: args, memory: raw.memory, cpuTime: raw.cpu)
    p.status = raw.status
    return p
  }
  public static func snapshot(includingOtherUsers: Bool = false) -> [Int32: Proc] {
    var ids = [Int32](repeating: 0, count: 32768)
    let count = dp_pids(&ids, Int32(ids.count))
    guard count > 0, count < ids.count else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: ids.prefix(Int(count)).filter { $0 > 0 }.compactMap { pid in
        guard let p = read(pid), includingOtherUsers || p.uid == getuid() else { return nil }
        return (pid, p)
      })
  }
  public static func signal(_ p: Proc, _ sig: Int32) throws {
    var raw = DPProcess()
    guard dp_read(p.pid, &raw) == 1, raw.start == p.identity.start, raw.unique == p.identity.unique,
      raw.version == p.identity.version
    else { throw SafetyError("Process exited or changed identity.") }
    let code = dp_signal(raw, sig)
    guard code == 0 else { throw SafetyError("Signal refused: \(String(cString:strerror(code)))") }
  }
  public static func output(_ path: String, _ args: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    guard
      process.terminationStatus == 0
        || (path.hasSuffix("lsof") && process.terminationStatus == 1 && data.isEmpty)
    else {
      throw SafetyError("Discovery command failed: \(URL(fileURLWithPath:path).lastPathComponent)")
    }
    return String(decoding: data, as: UTF8.self)
  }
  public static func nativeListeners(_ all: [Int32: Proc]) throws -> [Int32: [Int]] {
    var candidates = Set<Int32>()
    for p in all.values where Policy.kind(p, listening: true) != nil {
      candidates.formUnion(Policy.descendants(p.pid, all).map(\.pid))
    }
    var result: [Int32: [Int]] = [:]
    for pid in candidates {
      var ports = [Int32](repeating: 0, count: 1024)
      let count = dp_tcp_ports(pid, &ports, Int32(ports.count))
      if count == -ESRCH || count == -ENOENT { continue }
      guard count >= 0 else {
        throw SafetyError(
          "Socket inspection unavailable for PID \(pid): \(String(cString: strerror(-count)))")
      }
      guard let current = Native.read(pid), current.identity == all[pid]?.identity else { continue }
      if count > 0 { result[pid] = Array(Set(ports.prefix(Int(count)).map(Int.init))).sorted() }
    }
    return result
  }
  public static func listeners() throws -> [Int32: [Int]] {
    let text = try output(
      "/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn"])
    var pid: Int32 = 0
    var result: [Int32: [Int]] = [:]
    for line in text.split(separator: "\n") {
      if line.first == "p" { pid = Int32(line.dropFirst()) ?? 0 }
      if line.first == "n", let part = line.split(separator: ":").last, let port = Int(part),
        pid > 0
      {
        result[pid, default: []].append(port)
      }
    }
    return result.mapValues { Array(Set($0)).sorted() }
  }
}
public struct Scan: Sendable {
  public var workloads: [Workload]
  public var count: Int
  public var duration: Double
  public var date: Date
  public var usedSocketFallback: Bool = false
}
public final class Scanner {
  private var previous: [Int32: Proc] = [:]
  private var time = Date()
  private var orphans = Set<Identity>()
  private var launcherCache = LaunchOwnershipCache()
  public init() {}
  public func scan() throws -> Scan {
    let begin = Date()
    var all = Native.snapshot()
    let ports: [Int32: [Int]]
    var usedFallback = false
    do { ports = try Native.nativeListeners(all) } catch {
      ports = try Native.listeners()
      usedFallback = true
    }
    guard !all.isEmpty else { throw SafetyError("Process access unavailable.") }
    let elapsed = begin.timeIntervalSince(time)
    for (id, var p) in all {
      if let old = previous[id], old.identity == p.identity {
        if elapsed > 0, p.cpuTime >= old.cpuTime {
          p.cpu = Double(p.cpuTime - old.cpuTime) / 1e9 / elapsed * 100
          all[id] = p
        }
        if old.parent != 1, p.parent == 1, let parent = previous[old.parent],
          all[old.parent]?.identity != parent.identity
        {
          orphans.insert(p.identity)
        }
      }
    }
    orphans = orphans.intersection(Set(all.values.map(\.identity)))
    let oldLabels = launcherCache.current(in: all)
    var workloads = Policy.workloads(all, ports: ports, labels: oldLabels, orphans: orphans)
    // Promoted shell/npm roots, rather than only their listening children, own launch labels.
    if let labels = try? launcherCache.update(
      roots: workloads.map(\.root), processes: all,
      lookup: {
        let output = try Native.output("/bin/launchctl", ["list"])
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
          let c = line.split(whereSeparator: { $0.isWhitespace })
          if c.count >= 3, let pid = Int32(c[0]) { result[pid] = String(c[2]) }
        }
        return result
      }), labels != oldLabels
    {
      workloads = Policy.workloads(all, ports: ports, labels: labels, orphans: orphans)
    }
    previous = all
    time = begin
    return Scan(
      workloads: workloads, count: all.count, duration: Date().timeIntervalSince(begin),
      date: Date(), usedSocketFallback: usedFallback)
  }
}
public enum Controller {
  public static func stop(_ w: Workload) throws {
    let initial = Native.snapshot(includingOtherUsers: true)
    try Policy.validate(w, live: initial)
    guard !w.members.contains(where: { initial[$0.pid]?.status == 4 }) else {
      throw SafetyError("A process is already suspended. Refusing to change its state.")
    }
    if w.usesMinecraftController {
      // The audited controller sends Minecraft's console stop, waits for world save,
      // creates a backup, and cleans up its own caffeinate/tunnel children.
      try Policy.validate(w, live: Native.snapshot(includingOtherUsers: true))
      guard LocalControllers.isMinecraftController(w.root) else {
        throw SafetyError("Controller changed since discovery.")
      }
      try Native.signal(w.root, SIGTERM)
      let deadline = Date().addingTimeInterval(60)
      while Date() < deadline {
        if w.members.allSatisfy({ old in
          guard let now = Native.read(old.pid) else { return true }
          return now.identity != old.identity || now.status == 5
        }) {
          return
        }
        Thread.sleep(forTimeInterval: 0.2)
      }
      throw SafetyError("Minecraft is still saving or backing up. No force kill was sent.")
    }
    // Freeze parent first, then descendants. Validate the now-quiescent tree before TERM.
    var frozen: [Proc] = []
    defer { for p in frozen { try? Native.signal(p, SIGCONT) } }
    var pending = w.members
    while !pending.isEmpty {
      guard
        let index = pending.firstIndex(where: { candidate in
          candidate.pid == w.root.pid || frozen.contains(where: { $0.pid == candidate.parent })
        })
      else { throw SafetyError("Could not order process tree.") }
      let p = pending.remove(at: index)
      let live = Native.snapshot(includingOtherUsers: true)
      try Policy.validate(w, live: live)
      let ours = Set(frozen.map(\.identity))
      guard !w.members.contains(where: { !ours.contains($0.identity) && live[$0.pid]?.status == 4 })
      else {
        throw SafetyError(
          "Another process was suspended during Stop. Refusing to change its state.")
      }
      try Native.signal(p, SIGSTOP)
      frozen.append(p)
    }
    try Policy.validate(w, live: Native.snapshot(includingOtherUsers: true))
    for p in frozen { try Native.signal(p, SIGTERM) }
    for p in frozen { try? Native.signal(p, SIGCONT) }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      // Zombies have exited and can no longer run or own listeners.
      if w.members.allSatisfy({ old in
        guard let now = Native.read(old.pid) else { return true }
        return now.identity != old.identity || now.status == 5
      }) {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw SafetyError(
      "Termination requested, but some processes are still exiting. No force kill was sent.")
  }
}

/// Owns scan state on its own executor. Safety actions always take fresh uncached snapshots.
public actor ProcessMonitor {
  private let scanner = Scanner()
  public init() {}
  public func scan() throws -> Scan { try scanner.scan() }
}
