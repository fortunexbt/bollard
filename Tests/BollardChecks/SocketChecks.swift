import BollardCore
import Foundation

/// Opens a listener in this process and requires the scanner's socket source to report it with
/// this PID. A source that silently returns nothing, as macOS 27 does for the raw kernel table,
/// fails here whatever lsof says.
func ownListenerChecks() throws {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SafetyError("Could not create a socket.") }
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0, listen(fd, 1) == 0 else { throw SafetyError("Could not listen on loopback.") }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
  }
  let port = Int(UInt16(bigEndian: address.sin_port))
  let found = try Native.sockets()
  guard found.contains(where: { $0.pid == getpid() && $0.port == port }) else {
    throw SafetyError(
      "Own listener on port \(port) missing from \(found.count) listeners")
  }
  let scanned = try Scanner().scan()
  guard scanned.listeners.contains(where: { $0.pid == getpid() && $0.port == port }) else {
    throw SafetyError("Own listener on port \(port) missing from the scan")
  }
}

/// Read-only comparison of the descriptor walk against lsof for this user's listeners.
/// Listeners come and go between snapshots, so each Bollard listener must appear in the lsof
/// snapshot taken just before or just after it, and every port lsof saw both times must be present.
func socketParityChecks() throws {
  var checked = 0
  var compared = 0
  for _ in 0..<12 {
    let before = try lsofListeners()
    let native = try Scanner().scan().listeners.filter { $0.transport == .tcp }
    let after = try lsofListeners()
    let ports = Set(native.map(\.port))
    for port in Set(before.keys).intersection(after.keys) {
      precondition(ports.contains(port), "lsof saw port \(port) twice; Bollard missed it")
    }
    for l in native {
      let seen = before[l.port]?.contains(l.pid) == true || after[l.port]?.contains(l.pid) == true
      let transient = before[l.port] == nil && after[l.port] == nil
      precondition(
        seen || transient,
        "Port \(l.port): Bollard says PID \(l.pid), lsof says \(before[l.port] ?? []) / \(after[l.port] ?? [])"
      )
      if seen { compared += 1 }
    }
    checked += 1
  }
  guard compared > 0 else {
    throw SafetyError("No listeners were available; socket parity is unverified.")
  }
  print(
    "\(checked) read-only socket-walk/lsof parity checks passed across \(compared) listener comparisons"
  )
}
private func lsofListeners() throws -> [Int: Set<Int32>] {
  let text = try Native.output(
    "/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
    timeout: 20)
  var pid: Int32 = 0
  var result: [Int: Set<Int32>] = [:]
  for line in text.split(separator: "\n") {
    if line.first == "p" { pid = Int32(line.dropFirst()) ?? 0 }
    if line.first == "n", let part = line.split(separator: ":").last, let port = Int(part), pid > 0
    {
      result[port, default: []].insert(pid)
    }
  }
  return result
}
