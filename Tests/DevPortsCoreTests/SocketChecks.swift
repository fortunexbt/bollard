import DevPortsCore
import Foundation

func socketParityChecks() throws {
  var checked = 0
  var observedListeners = Set<String>()
  for _ in 0..<10 {
    let all = Native.snapshot()
    let before = try Native.listeners()
    let native = try Native.nativeListeners(all)
    let after = try Native.listeners()
    guard before == after else { continue }
    func signature(_ ports: [Int32: [Int]]) -> [String] {
      Policy.workloads(all, ports: ports).map { "\($0.root.pid):\($0.kind.name):\($0.ports)" }
        .sorted()
    }
    precondition(
      signature(native) == signature(after),
      "Native discovery differs from lsof: \(signature(native)) / \(signature(after))")
    for row in Policy.workloads(all, ports: after) {
      for port in row.ports { observedListeners.insert("\(row.root.pid):\(port)") }
    }
    checked += 1
  }
  precondition(checked >= 5, "Not enough stable live snapshots to confirm native socket parity")
  guard !observedListeners.isEmpty else {
    throw SafetyError("No live workload listeners were available; socket parity is unverified.")
  }
  print(
    "\(checked) read-only native/lsof parity checks passed across \(observedListeners.count) live listeners"
  )
}
