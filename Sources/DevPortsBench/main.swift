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
    "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
    "min": sorted.first!, "max": sorted.last!,
  ]
}
let scanner = Scanner()
let (first, firstScan) = try measured { try scanner.scan() }
var scans = [Double]()
var tables = [Double]()
var sockets = [Double]()
var snapshots = [Double]()
var policy = [Double]()
for _ in 0..<15 {
  let (_, full) = try measured { try scanner.scan() }
  scans.append(full)
  let (_, table) = try measured { try Native.table() }
  tables.append(table)
  let (listeners, socket) = try measured { try Native.listeners() }
  sockets.append(socket)
  let (all, snapshot) = try measured { try Native.snapshot() }
  snapshots.append(snapshot)
  let (_, classification) = measured { Policy.workloads(all, listeners: listeners) }
  policy.append(classification)
}
let result: [String: Any] = [
  "timestamp": ISO8601DateFormatter().string(from: Date()), "samples": 15,
  "first_scan_ms": firstScan,
  "steady_scan_ms": stats(scans), "process_table_ms": stats(tables),
  "socket_table_ms": stats(sockets),
  "uncached_snapshot_ms": stats(snapshots), "policy_ms": stats(policy),
  "process_count": first.count,
  "listeners": first.listeners.count, "workloads": first.workloads.count,
]
let data = try JSONSerialization.data(
  withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
