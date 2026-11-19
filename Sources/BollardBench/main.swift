import BollardCore
import Darwin
import Foundation

/// CPU milliseconds this thread spent in `operation`. Wall time says more about what else the Mac
/// is doing than about the scan, and a busy Mac is exactly when the panel gets opened.
func measured<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
  let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
  let value = try operation()
  return (value, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
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
var lean = [Double]()
var tables = [Double]()
var sockets = [Double]()
var snapshots = [Double]()
var policy = [Double]()
for _ in 0..<15 {
  let (_, full) = try measured { try scanner.scan() }
  scans.append(full)
  let (_, quiet) = try measured { try scanner.scan(sampling: false) }
  lean.append(quiet)
  let (_, table) = try measured { try Native.table() }
  tables.append(table)
  let (held, socket) = try measured { try Native.sockets() }
  sockets.append(socket)
  let (all, snapshot) = try measured { try Native.snapshot() }
  snapshots.append(snapshot)
  let listeners = Policy.owners(held, in: all)
  let (_, classification) = measured { Policy.workloads(all, listeners: listeners) }
  policy.append(classification)
}
let result: [String: Any] = [
  "timestamp": ISO8601DateFormatter().string(from: Date()), "samples": 15,
  "first_scan_cpu_ms": firstScan,
  "steady_scan_cpu_ms": stats(scans), "closed_panel_scan_cpu_ms": stats(lean),
  "process_table_cpu_ms": stats(tables),
  "socket_walk_cpu_ms": stats(sockets),
  "uncached_snapshot_cpu_ms": stats(snapshots), "policy_cpu_ms": stats(policy),
  "process_count": first.count,
  "listeners": first.listeners.count, "workloads": first.workloads.count,
]
let data = try JSONSerialization.data(
  withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
