import Darwin
import Foundation

/// Port availability probes that need no process table, so they keep working when discovery cannot.
public enum Ports {
  public static let dynamicEnd = 65535

  /// True when nothing holds the port on loopback or the wildcard addresses. Binding with
  /// SO_REUSEADDR ignores TIME_WAIT leftovers, the same way a dev server would bind.
  public static func isFree(_ port: Int) -> Bool {
    guard (1...dynamicEnd).contains(port) else { return false }
    return canBind(port, AF_INET, "0.0.0.0") && canBind(port, AF_INET, "127.0.0.1")
      && canBind(port, AF_INET6, "::") && canBind(port, AF_INET6, "::1")
  }

  /// True when something on this Mac accepts a TCP connection on the port.
  public static func isListening(_ port: Int) -> Bool {
    guard (1...dynamicEnd).contains(port) else { return false }
    return connects(port, AF_INET, "127.0.0.1") || connects(port, AF_INET6, "::1")
  }

  /// The first free port at or above `start`, or nil when none is left below 65536.
  public static func firstFree(from start: Int) -> Int? {
    guard start <= dynamicEnd else { return nil }
    return (max(start, 1)...dynamicEnd).first(where: isFree)
  }

  /// Polls until the port accepts connections (`listening`) or can be bound again (`!listening`).
  /// Returns whether the state was reached before the timeout.
  public static func wait(for port: Int, listening: Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if listening ? isListening(port) : isFree(port) { return true }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
  }

  /// Runs `body` with a sockaddr for the loopback or wildcard `host` on `port`.
  private static func withAddress(
    _ family: Int32, _ host: String, _ port: Int,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> Bool
  ) -> Bool {
    if family == AF_INET {
      var a = sockaddr_in()
      a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      a.sin_family = sa_family_t(AF_INET)
      a.sin_port = UInt16(port).bigEndian
      inet_pton(AF_INET, host, &a.sin_addr)
      return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = UInt16(port).bigEndian
    inet_pton(AF_INET6, host, &a.sin6_addr)
    return withUnsafePointer(to: &a) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  }

  private static func canBind(_ port: Int, _ family: Int32, _ host: String) -> Bool {
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    return withAddress(family, host, port) { bind(fd, $0, $1) == 0 }
  }

  private static func connects(_ port: Int, _ family: Int32, _ host: String) -> Bool {
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return withAddress(family, host, port) { connect(fd, $0, $1) == 0 }
  }
}
