import Darwin
import Foundation

/// What the whole Mac is doing, as the menu bar shows it.
public struct SystemSample: Sendable, Equatable {
  /// Share of all cores that were busy since the previous sample, 0 to 100.
  public var cpu: Double
  /// App memory, wired memory and the compressor: what Activity Monitor calls Memory Used.
  public var memoryUsed: UInt64
  public var memoryTotal: UInt64
  /// Bytes a second through the physical network interfaces since the previous sample.
  public var received: Double
  public var sent: Double
}

/// Reads the kernel's running totals and turns them into rates. Three system calls a sample, no
/// subprocesses. Not thread-safe; one owner calls `sample()` on a timer.
public final class SystemSampler {
  private var ticks: (busy: UInt64, total: UInt64) = (0, 0)
  private var bytes: (received: UInt64, sent: UInt64) = (0, 0)
  private var time = Date()
  private let total = ProcessInfo.processInfo.physicalMemory
  private let host = mach_host_self()
  public init() {
    ticks = Self.cpuTicks(host)
    bytes = Self.networkBytes()
  }

  public func sample() -> SystemSample {
    let now = Date()
    let elapsed = max(now.timeIntervalSince(time), 0.001)
    let nextTicks = Self.cpuTicks(host)
    let nextBytes = Self.networkBytes()
    defer {
      ticks = nextTicks
      bytes = nextBytes
      time = now
    }
    let span = Double(nextTicks.total &- ticks.total)
    // Interface counters restart when an interface does; a total that went backwards is no rate.
    func rate(_ new: UInt64, _ old: UInt64) -> Double {
      new >= old ? Double(new - old) / elapsed : 0
    }
    return SystemSample(
      cpu: span > 0 ? min(100, Double(nextTicks.busy &- ticks.busy) / span * 100) : 0,
      memoryUsed: Self.memoryUsed(host), memoryTotal: total,
      received: rate(nextBytes.received, bytes.received), sent: rate(nextBytes.sent, bytes.sent))
  }

  static func cpuTicks(_ host: mach_port_t) -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    let (user, system, idle, nice) = info.cpu_ticks
    let busy = UInt64(user) + UInt64(system) + UInt64(nice)
    return (busy, busy + UInt64(idle))
  }
  static func memoryUsed(_ host: mach_port_t) -> UInt64 {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let app =
      UInt64(info.internal_page_count)
      - min(
        UInt64(info.internal_page_count), UInt64(info.purgeable_count))
    let pages = app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
    return pages * UInt64(getpagesize())
  }
  /// Totals across the Ethernet and Wi-Fi interfaces. Loopback is left out, since a dev server
  /// talking to itself is not network use, and so are tunnels, whose traffic is already counted
  /// on the interface that carries it.
  static func networkBytes() -> (received: UInt64, sent: UInt64) {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return (0, 0) }
    defer { freeifaddrs(list) }
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var next = list
    while let entry = next {
      defer { next = entry.pointee.ifa_next }
      guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
        String(cString: entry.pointee.ifa_name).hasPrefix("en"),
        let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
      else { continue }
      received += UInt64(data.pointee.ifi_ibytes)
      sent += UInt64(data.pointee.ifi_obytes)
    }
    return (received, sent)
  }
}

/// `840K`, `1.2M`, `15M`, `1.1G`: a byte count or rate in at most four characters.
public func compactBytes(_ value: Double) -> String {
  let units = ["K", "M", "G", "T"]
  var scaled = max(value, 0) / 1000
  var unit = 0
  while scaled >= 999.5, unit < units.count - 1 {
    scaled /= 1000
    unit += 1
  }
  return
    (scaled < 9.95 && unit > 0 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled))
    + units[unit]
}
