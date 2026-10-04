import Darwin
import DevPortsCore
import Foundation

func measured<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let value = try operation()
  return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}
func stats(_ values: [Double]) -> [String: Double] {
  let sorted = values.sorted()
  return [
    "median": sorted[sorted.count / 2],
    "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "min": sorted.first!,
    "max": sorted.last!,
  ]
}
let scanner = Scanner()
var scans = [Double]()
var listeners = [Double]()
var snapshots = [Double]()
var labels = [Double]()
var policy = [Double]()
var workloadCount = 0
var processCount = 0
var fallbackScans = 0
for _ in 0..<15 {
  let (scan, full) = try measured { try scanner.scan() }
  if scan.usedSocketFallback { fallbackScans += 1 }
  scans.append(full)
  workloadCount = scan.workloads.count
  processCount = scan.count
  let (ports, sockets) = try measured { try Native.listeners() }
  listeners.append(sockets)
  let (all, processes) = measured { Native.snapshot() }
  snapshots.append(processes)
  let (_, launchctl) = try measured { try Native.output("/bin/launchctl", ["list"]) }
  labels.append(launchctl)
  let (_, classification) = measured { Policy.workloads(all, ports: ports) }
  policy.append(classification)
}
let result: [String: Any] = [
  "timestamp": ISO8601DateFormatter().string(from: Date()), "samples": 15,
  "fallback_scans": fallbackScans, "scan_ms": stats(scans),
  "lsof_ms": stats(listeners), "snapshot_ms": stats(snapshots), "launchctl_ms": stats(labels),
  "policy_ms": stats(policy), "process_count": processCount, "workloads": workloadCount,
]
let data = try JSONSerialization.data(
  withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
