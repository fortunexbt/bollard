import BollardCore
import Foundation

/// Read-only comparison of the kernel socket table against lsof for this user's listeners.
/// Listeners come and go between snapshots, so each Bollard listener must appear in the lsof
/// snapshot taken just before or just after it, and every port lsof saw both times must be present.
func socketParityChecks() throws {
  var checked = 0
  var compared = 0
  for _ in 0..<12 {
    let before = try lsofListeners()
    let native = try Scanner().scan().listeners.filter { $0.uid == getuid() }
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
    "\(checked) read-only socket-table/lsof parity checks passed across \(compared) listener comparisons"
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
