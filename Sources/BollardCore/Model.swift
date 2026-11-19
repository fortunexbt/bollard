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
  /// In the foreground process group of a terminal: what the user is looking at in a tab.
  public var foreground = false
  /// The process macOS holds responsible for this one, which outlives the parent. 0 when unknown.
  public var responsible: Int32 = 0
  public var comm: String
  public let path: String
  public var cwd: String
  public let args: [String]
  /// Lowercased executable name.
  public let base: String
  public var memory: UInt64
  public var cpuTime: UInt64
  public var cpu: Double = 0
  public var pid: Int32 { identity.pid }
  public var suspended: Bool { status == 4 }
  public var zombie: Bool { status == 5 }
  public var command: String { args.map(shellQuote).joined(separator: " ") }
  public func named(_ names: Set<String>) -> Bool {
    names.contains(base) || names.contains(argName)
  }
  // Everything below is derived from the path and arguments, which never change for a process
  // generation, so it is worked out once here and not on every scan.
  /// Lowercased name from the first argument; version-named binaries such as Claude Code's
  /// `versions/2.1.309` still identify themselves there.
  public let argName: String
  /// What it runs, with interpreters, runners and rewritten titles looked through.
  public let program: Program
  /// Outermost application bundle on the executable path, if any.
  public let outerBundle: String?
  /// The application this executable is part of. Runtimes and toolchains that ship inside a bundle,
  /// such as Xcode's Python or Homebrew's Python.app, run the user's code and belong to no app.
  public let appBundle: String?
  let traits: Policy.Traits
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
    argName = args.first.map { $0.split(separator: "/").last.map { $0.lowercased() } ?? "" } ?? ""
    program = Program(base: base, comm: comm, args: args)
    let outer = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    outerBundle = outer
    if let outer, path.contains(".xpc/") || path.contains(".appex/") {
      appBundle = outer
    } else if let outer, !outer.contains(".framework/"), !path.contains("/Contents/Developer/") {
      appBundle = outer
    } else {
      appBundle = nil
    }
    traits = Policy.traits(path: path, args: args, outerBundle: outer)
  }
}

/// A label for what a workload is. It never decides whether the workload is shown.
public struct Kind: Equatable, Sendable {
  public var name: String
  public var icon: String
  /// Speaks HTTP, so its port opens in a browser.
  public var web: Bool
  public init(name: String, icon: String, web: Bool = false) {
    self.name = name
    self.icon = icon
    self.web = web
  }
}

public enum Transport: String, Sendable {
  case tcp, udp, unix
}

/// A socket a workload can be reached on: listening TCP, bound UDP or a listening Unix socket.
public struct Listener: Hashable, Sendable {
  public var transport: Transport
  public var port: Int
  public var address: String
  public var wildcard: Bool
  /// File-system path of a Unix-domain socket.
  public var path: String
  public var pid: Int32
  public var socket: UInt64
  public init(
    port: Int, address: String = "127.0.0.1", wildcard: Bool = false, pid: Int32,
    transport: Transport = .tcp, path: String = "", socket: UInt64 = 0
  ) {
    self.transport = transport
    self.port = port
    self.address = address
    self.wildcard = wildcard
    self.path = path
    self.pid = pid
    self.socket = socket
  }
  /// `127.0.0.1:3000`, `*:5353/udp`, `[::1]:8080` or the socket path.
  public var text: String {
    if transport == .unix { return path }
    let host = wildcard ? "*" : address.contains(":") ? "[\(address)]" : address
    return "\(host):\(port)" + (transport == .udp ? "/udp" : "")
  }
}

public enum Lane: String, CaseIterable, Sendable {
  case servers = "Servers"
  case background = "Background"
  case agents = "Agents"
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
  /// The project it belongs to.
  public var name: String
  /// What it runs, short enough for a subtitle: `worker.py`, `next dev`, `-m http.server`.
  public var detail: String
  /// The process that does the work, below any shell or package-manager wrappers.
  public var lead: Proc
  public var listeners: [Listener]
  public var provenance: String
  public var orphan: Bool
  public var section: Lane
  /// Advisory notes shown before stopping. They never block the action.
  public var cautions: [String]
  /// A hard reason this workload cannot be signalled from Bollard.
  public var blocked: String?
  public var launchdLabel: String?
  /// A declared controller script owns this workload; Stop signals it instead of the tree.
  public var controller: ControllerScript?
  /// Git branch or worktree of the project directory, when it is a checkout.
  public var branch: String?
  /// Who launched it: Claude Code, Codex, Terminal, launchd and so on. Drives the origin filter.
  public var origin: String
  public var history: [Sample] = []
  public init(
    root: Proc, members: [Proc], excluded: [Proc], kind: Kind, name: String, detail: String = "",
    lead: Proc? = nil, listeners: [Listener], provenance: String, origin: String, orphan: Bool,
    section: Lane, cautions: [String], blocked: String?, launchdLabel: String?
  ) {
    self.root = root
    self.detail = detail
    self.lead = lead ?? root
    self.members = members
    self.excluded = excluded
    self.kind = kind
    self.name = name
    self.listeners = listeners
    self.provenance = provenance
    self.origin = origin
    self.orphan = orphan
    self.section = section
    self.cautions = cautions
    self.blocked = blocked
    self.launchdLabel = launchdLabel
  }
  public var ports: [Int] {
    Array(Set(listeners.filter { $0.transport != .unix }.map(\.port))).sorted()
  }
  /// TCP ports, the ones a browser or client connects to.
  public var tcpPorts: [Int] {
    Array(Set(listeners.filter { $0.transport == .tcp }.map(\.port))).sorted()
  }
  /// Where it listens, as text, without the IPv4 and IPv6 twins of one wildcard port.
  public var endpoints: [String] {
    var seen = Set<String>()
    return listeners.map(\.text).filter { seen.insert($0).inserted }
  }
  public var exposed: Bool { listeners.contains { $0.wildcard } }
  public var url: URL? {
    kind.web ? tcpPorts.first.flatMap { URL(string: "http://localhost:\($0)") } : nil
  }
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
