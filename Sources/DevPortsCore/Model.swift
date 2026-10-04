import CoreGraphics
import Foundation
import ProcessBridge

public struct Identity: Hashable, Codable, Sendable {
  public let pid: Int32
  public let start: UInt64
  public let unique: UInt64
  public let version: Int32
}
public struct Proc: Sendable {
  public var identity: Identity
  public var parent: Int32
  public var parentUnique: UInt64
  public var uid: UInt32
  public var path: String
  public var cwd: String
  public var args: [String]
  public var memory: UInt64
  public var cpuTime: UInt64
  public var cpu: Double = 0
  public var status: UInt32 = 0
  public var pid: Int32 { identity.pid }
  public var command: String { args.map(shellQuote).joined(separator: " ") }
  public var base: String { path.split(separator: "/").last.map { $0.lowercased() } ?? "" }
  public init(
    pid: Int32, parent: Int32, start: UInt64 = 1, unique: UInt64? = nil, version: Int32 = 1,
    parentUnique: UInt64 = 0, uid: UInt32 = getuid(), path: String, cwd: String = "/tmp/project",
    args: [String], memory: UInt64 = 0, cpuTime: UInt64 = 0
  ) {
    identity = Identity(pid: pid, start: start, unique: unique ?? UInt64(pid), version: version)
    self.parent = parent
    self.parentUnique = parentUnique
    self.uid = uid
    self.path = path
    self.cwd = cwd
    self.args = args
    self.memory = memory
    self.cpuTime = cpuTime
  }
}
public struct Kind: Equatable, Sendable {
  public var name: String
  public var icon: String
  public var web: Bool
  public var background: Bool = false
}
public struct Workload: Identifiable, Sendable {
  public var id: Identity { root.identity }
  public var root: Proc
  public var members: [Proc]
  public var kind: Kind
  public var name: String
  public var ports: [Int]
  public var provenance: String
  public var orphan: Bool
  public var refusal: String?
  public var memory: UInt64 { members.reduce(0) { $0 + $1.memory } }
  public var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
  public var uptime: TimeInterval {
    max(0, Date().timeIntervalSince1970 - Double(root.identity.start) / 1e6)
  }
  public var usesMinecraftController: Bool = false
  private var hasOriginalExecutable: Bool {
    guard let first = root.args.first, !first.contains(" ") else { return false }
    let name = URL(fileURLWithPath: first).lastPathComponent.lowercased()
    return name == root.base || (name.hasPrefix("python") && root.base.hasPrefix("python"))
  }
  public var restartReason: String? {
    refusal
      ?? (!hasOriginalExecutable
        ? "The process replaced its launch arguments; the original command is unavailable." : nil)
      ?? (root.parent == 1 && !usesMinecraftController
        ? "Detached or managed process: its original launch environment is unknown." : nil)
      ?? (root.args.isEmpty || root.cwd.isEmpty
        ? "Original command or directory is unavailable." : nil)
  }
}
public func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
public func memoryText(_ n: UInt64) -> String {
  n >= 1_000_000_000 ? String(format: "%.1f GB", Double(n) / 1e9) : "\(n/1_000_000) MB"
}
public func uptimeText(_ n: TimeInterval) -> String {
  let m = Int(n) / 60
  return m >= 60 ? "\(m/60)h \(m%60)m" : "\(m)m"
}

public enum PanelPlacement {
  public static func frame(
    anchor: CGRect, screen: CGRect, desiredHeight: Double, desiredWidth: Double = 480
  ) -> CGRect {
    let safe = screen.insetBy(dx: 8, dy: 8)
    let width = min(desiredWidth, safe.width)
    let height = min(desiredHeight, safe.height, 680)
    let x = max(safe.minX, min(anchor.maxX - width, safe.maxX - width))
    let y = max(safe.minY, min(anchor.minY - height - 6, safe.maxY - height))
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
