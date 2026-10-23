import Foundation
import ProcessBridge

/// Immutable-per-generation process facts, read once when a process is first seen.
struct Detail {
  var unique: UInt64
  var parentUnique: UInt64
  var version: Int32
  var path: String
  var args: [String]
}

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
  static func detail(_ pid: Int32) -> Detail? {
    var raw = DPIdentity()
    guard dp_identity(pid, &raw) == 1 else { return nil }
    let argv = [CChar](unsafeUninitializedCapacity: 262144) { buffer, initializedCount in
      initializedCount = max(0, Int(dp_args(pid, buffer.baseAddress!, Int32(buffer.count))))
    }
    let args = argv.split(separator: 0).map {
      String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return Detail(
      unique: raw.unique, parentUnique: raw.parent_unique, version: raw.version,
      path: cString(&raw.path), args: args)
  }
  static func cwd(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    return dp_cwd(pid, &buffer, Int32(buffer.count)) == 1 ? String(cString: buffer) : ""
  }
  static func usage(_ pid: Int32) -> (memory: UInt64, cpu: UInt64)? {
    var raw = DPUsage()
    return dp_usage(pid, &raw) == 1 ? (raw.memory, raw.cpu) : nil
  }
  /// A complete process record, used by control paths that must not trust a cached scan.
  public static func read(_ pid: Int32) -> Proc? {
    guard let entry = try? table().first(where: { $0.pid == pid }), let d = detail(pid) else {
      return nil
    }
    var p = Proc(
      pid: pid, parent: entry.ppid, start: entry.start, unique: d.unique, version: d.version,
      parentUnique: d.parentUnique, pgid: entry.pgid, uid: entry.uid, path: d.path,
      cwd: cwd(pid), args: d.args)
    p.status = entry.status
    if let u = usage(pid) {
      p.memory = u.memory
      p.cpuTime = u.cpu
    }
    return p
  }
  /// A complete uncached snapshot for control paths.
  public static func snapshot() throws -> [Int32: Proc] {
    let me = getuid()
    var all: [Int32: Proc] = [:]
    for e in try table() where e.pid > 0 {
      var comm = e.comm
      let name = cString(&comm)
      var p: Proc
      if e.uid == me, e.status != 5, let d = detail(e.pid) {
        p = Proc(
          pid: e.pid, parent: e.ppid, start: e.start, unique: d.unique, version: d.version,
          parentUnique: d.parentUnique, pgid: e.pgid, uid: e.uid, path: d.path, cwd: cwd(e.pid),
          args: d.args)
      } else {
        p = Proc(
          pid: e.pid, parent: e.ppid, start: e.start, unique: 0, version: 0, pgid: e.pgid,
          uid: e.uid, path: "", cwd: "", args: [])
      }
      p.status = e.status
      if p.comm.isEmpty { p.comm = name }
      all[e.pid] = p
    }
    return all
  }
  public static func listeners() throws -> [Listener] {
    var buffer = [DPListener](repeating: DPListener(), count: 4096)
    let count = dp_listeners(&buffer, Int32(buffer.count))
    guard count >= 0 else { throw SafetyError("Socket table unavailable: \(errorText(count))") }
    return buffer.prefix(Int(count)).map { raw in
      var l = raw
      let bytes = withUnsafeBytes(of: &l.address) { Array($0) }
      return Listener(
        port: Int(l.port), address: addressText(bytes, family: l.family), wildcard: l.wildcard != 0,
        pid: l.pid,
        uid: l.uid, socket: l.socket)
    }
  }
  static func addressText(_ bytes: [UInt8], family: UInt8) -> String {
    func dotted(_ slice: ArraySlice<UInt8>) -> String {
      slice.map { String($0) }.joined(separator: ".")
    }
    if family == 4 { return dotted(bytes[0..<4]) }
    let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    if mapped { return dotted(bytes[12..<16]) }
    if bytes.allSatisfy({ $0 == 0 }) { return "::" }
    var groups: [String] = []
    for i in stride(from: 0, to: 16, by: 2) {
      let value = Int(bytes[i]) << 8 | Int(bytes[i + 1])
      groups.append(String(value, radix: 16))
    }
    return groups.joined(separator: ":")
  }
  /// Read-only lsof fallback, used only when the kernel socket table cannot be parsed.
  public static func lsofListeners() throws -> [Listener] {
    let text = try output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpun"], timeout: 15)
    var pid: Int32 = 0
    var uid: UInt32 = 0
    var result: [Listener] = []
    for line in text.split(separator: "\n") {
      switch line.first {
      case "p": pid = Int32(line.dropFirst()) ?? 0
      case "u": uid = UInt32(line.dropFirst()) ?? 0
      case "n":
        guard let colon = line.lastIndex(of: ":"),
          let port = Int(line[line.index(after: colon)...]), pid > 0
        else { continue }
        let host = String(line[line.index(after: line.startIndex)..<colon])
        let wildcard = host == "*"
        result.append(
          Listener(
            port: port,
            address: wildcard
              ? "0.0.0.0" : host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            wildcard: wildcard, pid: pid, uid: uid, socket: UInt64(pid) << 16 | UInt64(port)))
      default: continue
      }
    }
    return result
  }
  public static func ownsSocket(_ pid: Int32, _ socket: UInt64) -> Bool {
    dp_owns_socket(pid, socket) == 1
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
    guard
      process.terminationStatus == 0 || (path.hasSuffix("lsof") && process.terminationStatus == 1)
    else {
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
  public var usedSocketFallback = false
}

/// Builds a process snapshot cheaply: one kernel call for the table, one for sockets, and
/// per-process detail only for generations not seen before.
public final class Scanner {
  private struct Key: Hashable {
    let pid: Int32
    let start: UInt64
  }
  private var details: [Key: Detail] = [:]
  private var cwds: [Key: String] = [:]
  private var previous: [Int32: Proc] = [:]
  private var time = Date()
  private var orphans = Set<Identity>()
  private struct SocketKey: Hashable {
    let socket: UInt64
    let port: Int
    let reported: Int32
  }
  private var verifiedSockets: [SocketKey: Int32] = [:]
  private var launcherCache = LaunchOwnershipCache()
  private var history: [Identity: [Sample]] = [:]
  public init() {}

  public func scan() throws -> Scan {
    let begin = Date()
    let entries = try Native.table()
    let me = getuid()
    let live = Set(entries.map { Key(pid: $0.pid, start: $0.start) })
    details = details.filter { live.contains($0.key) }
    cwds = cwds.filter { live.contains($0.key) }
    var all: [Int32: Proc] = [:]
    all.reserveCapacity(entries.count)
    for e in entries where e.pid > 0 {
      let key = Key(pid: e.pid, start: e.start)
      var comm = e.comm
      let name = Native.cString(&comm)
      if e.uid == me, e.status != 5 {
        guard let d = details[key] ?? Native.detail(e.pid) else { continue }
        details[key] = d
        let cwd = cwds[key] ?? Native.cwd(e.pid)
        cwds[key] = cwd
        var p = Proc(
          pid: e.pid, parent: e.ppid, start: e.start, unique: d.unique, version: d.version,
          parentUnique: d.parentUnique, pgid: e.pgid, uid: e.uid, path: d.path, cwd: cwd,
          args: d.args)
        p.status = e.status
        if p.comm.isEmpty { p.comm = name }
        all[e.pid] = p
      } else {
        var p = Proc(
          pid: e.pid, parent: e.ppid, start: e.start, unique: 0, version: 0, pgid: e.pgid,
          uid: e.uid, path: "", cwd: "", args: [])
        p.status = e.status
        p.comm = name
        all[e.pid] = p
      }
    }
    guard !all.isEmpty else { throw SafetyError("Process access unavailable.") }
    var usedFallback = false
    let listeners: [Listener]
    do {
      listeners = verify(try Native.listeners(), all)
    } catch {
      // A changed kernel socket-table layout must degrade, not blind the app.
      listeners = try Native.lsofListeners()
      usedFallback = true
    }
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
    if let fresh = try? launcherCache.update(
      roots: workloads.map(\.root), processes: all, lookup: Native.launchdLabels), fresh != labels
    {
      workloads = Policy.workloads(all, listeners: listeners, labels: fresh, orphans: orphans)
    }
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
      }
      workloads[index].branch = Git.branch(for: workloads[index].root.cwd)
      let w = workloads[index]
      var samples = history[w.id] ?? []
      samples.append(Sample(cpu: w.cpu, memory: w.memory))
      if samples.count > 60 { samples.removeFirst(samples.count - 60) }
      history[w.id] = samples
      workloads[index].history = samples
      // Directories can change after launch; refresh the displayed root's each scan.
      let key = Key(pid: w.root.pid, start: w.root.identity.start)
      let cwd = Native.cwd(w.root.pid)
      if !cwd.isEmpty { cwds[key] = cwd }
    }
    history = history.filter { entry in workloads.contains { $0.id == entry.key } }
    for (pid, p) in sampled { all[pid] = p }
    previous = all
    time = begin
    return Scan(
      workloads: workloads, listeners: listeners, count: all.count,
      duration: Date().timeIntervalSince(begin), date: Date(), usedSocketFallback: usedFallback)
  }

  /// The socket table names the last process that touched each socket. Confirm ownership through
  /// the process's descriptors the first time a socket is seen, and repair inherited sockets.
  private func verify(_ listeners: [Listener], _ all: [Int32: Proc]) -> [Listener] {
    let me = getuid()
    var seen = Set<SocketKey>()
    let result = listeners.map { l -> Listener in
      let key = SocketKey(socket: l.socket, port: l.port, reported: l.pid)
      seen.insert(key)
      guard l.uid == me else { return l }
      if let pid = verifiedSockets[key], all[pid] != nil {
        var v = l
        v.pid = pid
        return v
      }
      var candidates = [l.pid]
      if let p = all[l.pid] {
        candidates += all.values.filter { $0.parent == l.pid || $0.pid == p.parent }.map(\.pid)
      }
      candidates += all.values.filter { $0.uid == me }.sorted {
        $0.identity.start > $1.identity.start
      }.map(\.pid)
      var checked = Set<Int32>()
      for pid in candidates where checked.insert(pid).inserted {
        if Native.ownsSocket(pid, l.socket) {
          verifiedSockets[key] = pid
          var v = l
          v.pid = pid
          return v
        }
      }
      return l
    }
    verifiedSockets = verifiedSockets.filter { seen.contains($0.key) }
    return result
  }
}

/// Owns scan state on its own executor. Control actions always take fresh snapshots.
public actor ProcessMonitor {
  private let scanner = Scanner()
  public init() {}
  public func scan() throws -> Scan { try scanner.scan() }
}
