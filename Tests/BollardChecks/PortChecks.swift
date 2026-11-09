import BollardCore
import Foundation

/// A loopback listener on an OS-chosen port, closed by `close()` or on deinit.
private final class Listener {
  private(set) var fd: Int32
  let port: Int

  init?(family: Int32) {
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var bound = false
    var chosen = 0
    if family == AF_INET {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
        }
      }
      chosen = Int(UInt16(bigEndian: address.sin_port))
    } else {
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_addr = in6addr_loopback
      var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
      bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
        }
      }
      chosen = Int(UInt16(bigEndian: address.sin6_port))
    }
    guard bound, chosen > 0 else {
      Darwin.close(fd)
      return nil
    }
    self.fd = fd
    port = chosen
  }

  func close() {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
  }

  deinit { close() }
}

/// Port probes against in-process listeners, so they hold without any process discovery.
func portChecks() {
  for family in [AF_INET, AF_INET6] {
    guard let held = Listener(family: family) else {
      if family == AF_INET { fatalError("PortChecks.swift: could not open a loopback listener") }
      continue
    }
    let port = held.port
    func require(_ condition: Bool, _ message: String) {
      if !condition {
        held.close()
        fatalError("PortChecks.swift: family \(family) port \(port): \(message)")
      }
    }
    require(!Ports.isFree(port), "must read as busy")
    require(Ports.isListening(port), "must accept connections")
    require(Ports.wait(for: port, listening: true, timeout: 1), "wait for a ready port")
    require(!Ports.wait(for: port, listening: false, timeout: 0.3), "wait for free must time out")
    require((Ports.firstFree(from: port) ?? 0) > port, "firstFree must skip a busy port")
    held.close()
    require(Ports.isFree(port), "must be free once closed")
    require(!Ports.isListening(port), "must stop accepting once closed")
    require(Ports.wait(for: port, listening: false, timeout: 1), "wait for a freed port")
    require(Ports.firstFree(from: port) == port, "firstFree returns a free start port")
  }
  precondition(!Ports.isFree(0) && !Ports.isFree(65536), "out of range ports are never free")
  precondition(Ports.firstFree(from: 65536) == nil, "no port above 65535")
  print("Port checks passed: busy, listening, wait, first free, freed, out of range")
}
