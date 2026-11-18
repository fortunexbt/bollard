import Foundation
import ProcessBridge

public enum Native {
  static func cString<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) {
      $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
  }
  public static func table() throws -> [DPEntry] {
    var buffer = [DPEntry](repeating: DPEntry(), count: 8192)
    let count = dp_table(&buffer, Int32(buffer.count))
    guard count > 0 else { throw SafetyError("Process table unavailable: \(errorText(count))") }
    return Array(buffer.prefix(Int(count)))
  }
  private static let argumentCapacity = 262144
  /// A full record for one of this user's processes, or the kernel's bare entry for anyone else's.
  static func proc(_ e: DPEntry, me: uid_t) -> Proc? {
    var comm = e.comm
    let name = cString(&comm)
    var raw = DPIdentity()
    guard e.uid == me, e.status != 5 else {
      var p = Proc(
        pid: e.pid, parent: e.ppid, start: e.start, unique: 0, version: 0, pgid: e.pgid,
        uid: e.uid, path: "", cwd: "", args: [])
      p.status = e.status
      p.comm = name
      return p
    }
    guard dp_identity(e.pid, &raw) == 1 else { return nil }
    let argv = [CChar](unsafeUninitializedCapacity: argumentCapacity) { buffer, count in
      count = max(0, Int(dp_args(e.pid, buffer.baseAddress!, Int32(buffer.count))))
    }
    let args = argv.split(separator: 0).map {
      String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    var p = Proc(
      pid: e.pid, parent: e.ppid, start: e.start, unique: raw.unique, version: raw.version,
      parentUnique: raw.parent_unique, pgid: e.pgid, uid: e.uid, path: cString(&raw.path),
      cwd: cwd(e.pid), args: args)
    p.status = e.status
    p.foreground = e.foreground != 0
    p.responsible = dp_responsible(e.pid)
    if p.comm.isEmpty { p.comm = name }
    return p
  }
  /// The process generation, which exec advances. 0 when the process is gone.
  static func generation(_ pid: Int32) -> Int32 { dp_generation(pid) }
  static func cwd(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard dp_cwd(pid, &buffer, Int32(buffer.count)) == 1 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
  static func usage(_ pid: Int32) -> (memory: UInt64, cpu: UInt64)? {
    var raw = DPUsage()
    return dp_usage(pid, &raw) == 1 ? (raw.memory, raw.cpu) : nil
  }
  /// A complete uncached snapshot for control paths, which must not trust a cached scan.
  public static func snapshot() throws -> [Int32: Proc] {
    let me = getuid()
    var all: [Int32: Proc] = [:]
    for e in try table() where e.pid > 0 {
      guard var p = proc(e, me: me) else { continue }
      if let u = usage(e.pid) {
        p.memory = u.memory
        p.cpuTime = u.cpu
      }
      all[e.pid] = p
    }
    return all
  }
  /// Every socket this user's processes can be reached on, one record per holding process.
  public static func sockets() throws -> [Listener] {
    var raw: UnsafeMutablePointer<DPSocket>?
    let count = dp_sockets(&raw)
    defer { free(raw) }
    guard count >= 0 else { throw SafetyError("Sockets unavailable: \(errorText(count))") }
    return UnsafeBufferPointer(start: raw, count: Int(count)).map { s in
      var s = s
      let transport: Transport =
        s.transport == DP_UDP ? .udp : s.transport == DP_UNIX ? .unix : .tcp
      return Listener(
        port: Int(s.port), address: transport == .unix ? "" : addressText(&s.address, s.family),
        wildcard: s.wildcard != 0, pid: s.pid, transport: transport,
        path: transport == .unix ? cString(&s.path) : "", socket: s.socket)
    }
  }
  static func addressText<T>(_ address: inout T, _ family: UInt8) -> String {
    withUnsafeBytes(of: &address) { bytes in
      // An IPv4 listener on a dual-stack socket reads better as the IPv4 address it is.
      let mapped =
        family == 6 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff
        && bytes[11] == 0xff
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      if family == 4 || mapped {
        inet_ntop(AF_INET, bytes.baseAddress! + (mapped ? 12 : 0), &text, socklen_t(text.count))
      } else {
        inet_ntop(AF_INET6, bytes.baseAddress!, &text, socklen_t(text.count))
      }
      return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }
  public static func signal(_ p: Proc, _ sig: Int32) throws {
    let code = dp_signal(p.pid, p.identity.start, p.identity.unique, p.identity.version, sig)
    guard code == 0 else {
      throw SafetyError(
        code == ESRCH
          ? "Process \(p.pid) already exited or changed identity."
          : "Signal refused for \(p.pid): \(errorText(-code))")
    }
  }
  static func errorText(_ code: Int32) -> String { String(cString: strerror(abs(code))) }
  public static func output(_ path: String, _ args: [String], timeout: TimeInterval = 3) throws
    -> String
  {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      let name = URL(fileURLWithPath: path).lastPathComponent
      let line =
        text.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
      throw SafetyError("\(name): \(line)")
    }
    return text
  }
  public static func launchdLabels() throws -> [Int32: String] {
    var result: [Int32: String] = [:]
    for line in try output("/bin/launchctl", ["list"]).split(separator: "\n") {
      let c = line.split(whereSeparator: { $0.isWhitespace })
      if c.count >= 3, let pid = Int32(c[0]) { result[pid] = String(c[2]) }
    }
    return result
  }
}

public struct Scan: Sendable {
  public var workloads: [Workload]
  public var listeners: [Listener]
  public var count: Int
  public var duration: Double
  public var date: Date
}

/// Builds a process snapshot cheaply: one kernel call for the table, one descriptor walk for
/// sockets, and the per-process reads only for generations not seen before.
public final class Scanner {
  private struct Key: Hashable {
    let pid: Int32
    let start: UInt64
  }
  /// Records by generation, with the kernel's name for the process at the time it was read.
  private var known: [Key: (proc: Proc, comm: String)] = [:]
  private var previous: [Int32: Proc] = [:]
  private var time = Date()
  private var orphans = Set<Identity>()
  private var launcherCache = LaunchOwnershipCache()
  private var history: [Identity: [Sample]] = [:]
  public init() {}

  public func scan() throws -> Scan { try scan(retry: true) }

  private func scan(retry: Bool) throws -> Scan {
    let begin = Date()
    let entries = try Native.table()
    let me = getuid()
    var all: [Int32: Proc] = [:]
    all.reserveCapacity(entries.count)
    var live: [Key: (proc: Proc, comm: String)] = [:]
    for e in entries where e.pid > 0 {
      let key = Key(pid: e.pid, start: e.start)
      var comm = e.comm
      let name = Native.cString(&comm)
      // exec keeps the PID and start time but replaces the program, so a changed name means the
      // cached record describes something that no longer exists.
      let cached = known[key].flatMap { $0.comm == name ? $0.proc : nil }
      guard var p = cached ?? Native.proc(e, me: me) else { continue }
      p.parent = e.ppid
      p.pgid = e.pgid
      p.status = e.status
      p.foreground = e.foreground != 0
      p.cpu = 0
      live[key] = (p, name)
      all[e.pid] = p
    }
    known = live
    guard !all.isEmpty else { throw SafetyError("Process access unavailable.") }
    let listeners = Policy.owners(try Native.sockets(), in: all)
    let elapsed = begin.timeIntervalSince(time)
    for (id, p) in all where p.uid == me {
      if let old = previous[id], old.identity == p.identity, old.parent != 1, p.parent == 1,
        let parent = previous[old.parent], all[old.parent]?.identity != parent.identity
      {
        orphans.insert(p.identity)
      }
    }
    orphans = orphans.intersection(Set(all.values.map(\.identity)))
    let labels = launcherCache.current(in: all)
    var workloads = Policy.workloads(all, listeners: listeners, labels: labels, orphans: orphans)
    // Roots a label has hidden, such as Apple's own agents, stay in the lookup set; dropping them
    // would forget the label and show them again on the next scan.
    let roots = workloads.map(\.root) + labels.keys.compactMap { all[$0] }
    if let fresh = try? launcherCache.update(
      roots: roots, processes: all, lookup: Native.launchdLabels), fresh != labels
    {
      workloads = Policy.workloads(all, listeners: listeners, labels: fresh, orphans: orphans)
    }
    // An exec into a program of the same name is only visible in the process generation. Check it
    // for what is on display, where a stale record would mislabel a row or refuse a Stop.
    var stale = false
    for p in workloads.flatMap(\.members) where Native.generation(p.pid) != p.identity.version {
      known[Key(pid: p.pid, start: p.identity.start)] = nil
      stale = true
    }
    if stale, retry { return try scan(retry: false) }
    // Resource sampling only for processes that are displayed.
    var sampled: [Int32: Proc] = [:]
    for index in workloads.indices {
      for m in workloads[index].members.indices {
        var p = workloads[index].members[m]
        if let s = sampled[p.pid] {
          p = s
        } else {
          if let u = Native.usage(p.pid) {
            p.memory = u.memory
            p.cpuTime = u.cpu
            if elapsed > 0, let old = previous[p.pid], old.identity == p.identity,
              u.cpu >= old.cpuTime
            {
              p.cpu = Double(u.cpu - old.cpuTime) / 1e9 / elapsed * 100
            }
          }
          sampled[p.pid] = p
        }
        workloads[index].members[m] = p
        if p.pid == workloads[index].root.pid { workloads[index].root = p }
        if p.pid == workloads[index].lead.pid { workloads[index].lead = p }
      }
      let w = workloads[index]
      var samples = history[w.id] ?? []
      samples.append(Sample(cpu: w.cpu, memory: w.memory))
      if samples.count > 60 { samples.removeFirst(samples.count - 60) }
      history[w.id] = samples
      workloads[index].history = samples
      // Directories can change after launch; reread the ones on display for the next scan.
      for p in [w.root, w.lead] {
        let cwd = Native.cwd(p.pid)
        if !cwd.isEmpty { known[Key(pid: p.pid, start: p.identity.start)]?.proc.cwd = cwd }
      }
    }
    let shown = Set(workloads.map(\.id))
    history = history.filter { shown.contains($0.key) }
    for (pid, p) in sampled {
      all[pid] = p
      known[Key(pid: pid, start: p.identity.start)]?.proc.memory = p.memory
      known[Key(pid: pid, start: p.identity.start)]?.proc.cpuTime = p.cpuTime
    }
    previous = all
    time = begin
    return Scan(
      workloads: workloads, listeners: listeners, count: all.count,
      duration: Date().timeIntervalSince(begin), date: Date())
  }
}

/// Owns scan state on its own executor. Control actions always take fresh snapshots.
public actor ProcessMonitor {
  private let scanner = Scanner()
  public init() {}
  public func scan() throws -> Scan { try scanner.scan() }
}
