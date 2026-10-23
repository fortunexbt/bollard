import CoreGraphics
import Foundation

public struct Identity: Hashable, Codable, Sendable {
  public let pid: Int32
  public let start: UInt64
  public let unique: UInt64
  public let version: Int32
  public init(pid: Int32, start: UInt64, unique: UInt64, version: Int32) {
    self.pid = pid
    self.start = start
    self.unique = unique
    self.version = version
  }
}

public struct Proc: Sendable {
  public var identity: Identity
  public var parent: Int32
  public var pgid: Int32
  public var parentUnique: UInt64
  public var uid: UInt32
  public var status: UInt32 = 0
  public var comm: String
  public let path: String
  public var cwd: String
  public let args: [String]
  /// Lowercased executable name, and the lowercased command line, computed once per process.
  public let base: String
  public let text: String
  public var memory: UInt64
  public var cpuTime: UInt64
  public var cpu: Double = 0
  public var pid: Int32 { identity.pid }
  public var suspended: Bool { status == 4 }
  public var zombie: Bool { status == 5 }
  public var command: String { args.map(shellQuote).joined(separator: " ") }
  public func has(_ needle: String) -> Bool { text.has(needle) }
  /// Lowercased name from the first argument; version-named binaries such as Claude Code's
  /// `versions/2.1.309` still identify themselves there.
  public var argName: String {
    args.first.map { $0.split(separator: "/").last.map { $0.lowercased() } ?? "" } ?? ""
  }
  public func named(_ names: Set<String>) -> Bool {
    names.contains(base) || names.contains(argName)
  }
  /// Outermost application bundle on the executable path, if any.
  public var outerBundle: String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
  }
  /// The application this executable belongs to on its own. Framework-embedded executables such
  /// as Xcode's Python or a browser's helper are only app members when their parent shares the bundle.
  public var appBundle: String? { path.has(".framework/") ? nil : outerBundle }
  public init(
    pid: Int32, parent: Int32, start: UInt64 = 1, unique: UInt64? = nil, version: Int32 = 1,
    parentUnique: UInt64 = 0, pgid: Int32? = nil, uid: UInt32 = getuid(), path: String,
    cwd: String = "/tmp/project", args: [String], memory: UInt64 = 0, cpuTime: UInt64 = 0
  ) {
    identity = Identity(pid: pid, start: start, unique: unique ?? UInt64(pid), version: version)
    self.parent = parent
    self.pgid = pgid ?? pid
    self.parentUnique = parentUnique
    self.uid = uid
    self.path = path
    self.cwd = cwd
    self.args = args
    self.memory = memory
    self.cpuTime = cpuTime
    comm = String(path.split(separator: "/").last ?? "")
    base = comm.lowercased()
    text = args.joined(separator: " ").lowercased()
  }
}

extension String {
  /// Byte-level substring search through libc's memmem; Foundation's locale-aware `contains`
  /// and generic collection searches are orders of magnitude slower on long command lines.
  public func has(_ needle: String) -> Bool {
    guard !needle.isEmpty else { return false }
    var haystack = self
    var pattern = needle
    return haystack.withUTF8 { h in
      pattern.withUTF8 { n in
        guard h.count >= n.count, let hb = h.baseAddress, let nb = n.baseAddress else {
          return false
        }
        return memmem(hb, h.count, nb, n.count) != nil
      }
    }
  }
}

public struct Kind: Equatable, Sendable {
  public var name: String
  public var icon: String
  public var web: Bool
  public var background: Bool = false
  public init(name: String, icon: String, web: Bool, background: Bool = false) {
    self.name = name
    self.icon = icon
    self.web = web
    self.background = background
  }
}

/// A TCP socket in the LISTEN state.
public struct Listener: Hashable, Sendable {
  public var port: Int
  public var address: String
  public var wildcard: Bool
  public var pid: Int32
  public var uid: UInt32
  public var socket: UInt64
  public init(
    port: Int, address: String = "127.0.0.1", wildcard: Bool = false, pid: Int32,
    uid: UInt32 = getuid(), socket: UInt64 = 0
  ) {
    self.port = port
    self.address = address
    self.wildcard = wildcard
    self.pid = pid
    self.uid = uid
    self.socket = socket
  }
}

public enum Lane: String, CaseIterable, Sendable {
  case servers = "Servers"
  case background = "Background"
  case apps = "Apps"
  case system = "System & tools"
}

public struct Sample: Sendable, Equatable {
  public var cpu: Double
  public var memory: UInt64
}

public struct Workload: Identifiable, Sendable {
  public var id: Identity { root.identity }
  public var root: Proc
  /// Processes a Stop signals: the root's tree minus protected processes and their subtrees.
  public var members: [Proc]
  /// Protected processes inside the tree that Stop leaves running.
  public var excluded: [Proc]
  public var kind: Kind
  public var name: String
  public var listeners: [Listener]
  public var provenance: String
  public var orphan: Bool
  public var section: Lane
  /// Advisory notes shown before stopping. They never block the action.
  public var cautions: [String]
  /// A hard reason this workload cannot be signalled from DevPorts.
  public var blocked: String?
  public var launchdLabel: String?
  public var usesMinecraftController = false
  public var history: [Sample] = []
  public var ports: [Int] { Array(Set(listeners.map(\.port))).sorted() }
  public var exposed: Bool { listeners.contains { $0.wildcard } }
  public var memory: UInt64 { members.reduce(0) { $0 + $1.memory } }
  public var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
  public var suspended: Bool { members.contains { $0.suspended } }
  public var brewService: String? {
    launchdLabel.flatMap { $0.hasPrefix("homebrew.mxcl.") ? String($0.dropFirst(14)) : nil }
  }
  public var uptime: TimeInterval {
    max(0, Date().timeIntervalSince1970 - Double(root.identity.start) / 1e6)
  }
  private var hasOriginalExecutable: Bool {
    guard let first = root.args.first, !first.contains(" ") else { return false }
    let name = URL(fileURLWithPath: first).lastPathComponent.lowercased()
    return name == root.base || (name.hasPrefix("python") && root.base.hasPrefix("python"))
  }
  public var restartReason: String? {
    blocked
      ?? (section == .apps ? "Applications restart from the Finder or Dock." : nil)
      ?? (!hasOriginalExecutable
        ? "The process replaced its launch arguments; the original command is unavailable." : nil)
      ?? (launchdLabel != nil
        ? "launchd owns this service; restart it with launchctl or brew." : nil)
      ?? (root.args.isEmpty || root.cwd.isEmpty
        ? "Original command or directory is unavailable." : nil)
  }
}

public func shellQuote(_ s: String) -> String {
  s.isEmpty || s.contains(where: { !$0.isLetter && !$0.isNumber && !"-_./:=@%+,".contains($0) })
    ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
}
public func memoryText(_ n: UInt64) -> String {
  n >= 1_000_000_000 ? String(format: "%.1f GB", Double(n) / 1e9) : "\(n/1_000_000) MB"
}
public func uptimeText(_ n: TimeInterval) -> String {
  let s = Int(n)
  if s < 60 { return "\(s)s" }
  let m = s / 60
  if m < 60 { return "\(m)m" }
  let h = m / 60
  if h < 48 { return "\(h)h \(m%60)m" }
  return "\(h/24)d \(h%24)h"
}

public enum PanelPlacement {
  public static func frame(
    anchor: CGRect, screen: CGRect, desiredHeight: Double, desiredWidth: Double = 500
  ) -> CGRect {
    let safe = screen.insetBy(dx: 8, dy: 8)
    let width = min(desiredWidth, safe.width)
    let height = min(desiredHeight, safe.height, 760)
    let x = max(safe.minX, min(anchor.maxX - width, safe.maxX - width))
    let y = max(safe.minY, min(anchor.minY - height - 6, safe.maxY - height))
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
