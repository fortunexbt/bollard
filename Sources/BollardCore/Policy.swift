import Foundation

/// Decides what is shown and what may be signalled.
///
/// Discovery is by structure, not by a list of known programs. Every process of this user has a
/// role: part of macOS, part of an application, a coding agent, a terminal session, or none of
/// those. A process with none of those roles is the user's own work, and the tree it belongs to is
/// a workload whether or not Bollard recognises what it runs.
public enum Policy {
  static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "nu"]
  /// Coding agents by executable, module or package name.
  static let agents: [String: String] = [
    "claude": "Claude Code", "@anthropic-ai/claude-code": "Claude Code", "codex": "Codex",
    "@openai/codex": "Codex", "gemini": "Gemini CLI", "@google/gemini-cli": "Gemini CLI",
    "opencode": "OpenCode", "opencode-ai": "OpenCode", "aider": "Aider",
    "cursor-agent": "Cursor Agent", "hermes": "Hermes", "hermes.cli": "Hermes",
  ]
  static let sessions: Set<String> = [
    "tmux", "screen", "zellij", "login", "sshd", "sudo", "su", "launchd", "mosh-server", "script",
  ]
  /// Full-screen and prompt programs. Hidden only while they hold a terminal's foreground, where
  /// they are something the user is looking at rather than something left running.
  static let interactive: Set<String> = [
    "vim", "nvim", "vi", "nano", "emacs", "hx", "micro", "less", "more", "man", "most", "bat",
    "htop", "top", "btop", "btm", "glances", "lazygit", "tig", "gitui", "fzf", "k9s", "lazydocker",
    "ranger", "nnn", "yazi", "mc", "psql", "mysql", "sqlite3", "redis-cli", "mongosh", "pgcli",
    "lldb", "gdb", "irb", "pry", "ipython", "bpython", "git", "gh",
  ]
  static let terminalApps = [
    "/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/Warp.app/", "/ChatGPT.app/",
    "/Visual Studio Code.app/", "/Zed.app/", "/Cursor.app/", "/Xcode.app/", "/Claude.app/",
  ]
  /// A workload with no socket has to live this long before it is listed, so one-shot commands
  /// never flicker through the panel.
  public static let settleTime: Double = 3

  /// Bollard's own ancestors: the shell, terminal or agent it was started from.
  static let ownAncestors: Set<Int32> = {
    let parents = Dictionary(
      (try? Native.table())?.map { ($0.pid, $0.ppid) } ?? [], uniquingKeysWith: { a, _ in a })
    var result = Set<Int32>()
    var pid = getppid()
    while pid > 1, result.insert(pid).inserted, let next = parents[pid] { pid = next }
    return result
  }()

  enum Role: Equatable {
    case system, session, user
    case app(String)
    case agent(String)
  }

  static func systemPath(_ path: String) -> Bool {
    ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains {
      path.hasPrefix($0)
    }
  }
  /// The agent this process is, by its executable, its first argument or the package it runs.
  package static func agent(_ p: Proc, _ program: Program? = nil) -> String? {
    // The Claude desktop application shares its name with the agent it embeds.
    if let outer = p.outerBundle, outer.hasPrefix("/Applications/"),
      p.path.hasPrefix(outer + "/Contents/MacOS/")
    {
      return nil
    }
    if let name = agents[p.base] ?? agents[p.argName] { return name }
    guard
      let program = program
        ?? (Program.runtimes.contains { p.base.hasPrefix($0.prefix) } ? Program(p) : nil),
      program.named
    else { return nil }
    return agents[program.target]
  }
  /// Why a terminal-bound process is part of a session rather than a workload, or nil.
  static func session(_ p: Proc, _ program: Program) -> String? {
    if p.named(sessions) || sessions.contains(program.target) {
      return "a login or session process"
    }
    if shells.contains(p.base), program.repl { return "an interactive shell" }
    if p.base == "ssh", !Kinds.tunnel(p) { return "a remote session" }
    if p.foreground, program.repl || interactive.contains(program.target) {
      return "an interactive terminal program"
    }
    return nil
  }
  static func role(_ p: Proc, in all: [Int32: Proc]) -> (role: Role, program: Program?) {
    if p.pid <= 1 || p.base == "launchd" { return (.system, nil) }
    // Bollard and whatever it was started from are the observer, never the observed.
    if p.pid == getpid() || ownAncestors.contains(p.pid) {
      return (agent(p).map(Role.agent) ?? .session, nil)
    }
    if systemPath(p.path) || p.path.contains(".xpc/Contents/MacOS/") { return (.system, nil) }
    if let name = agent(p) { return (.agent(name), nil) }
    if let bundle = bundle(p, in: all) { return (.app(bundle), nil) }
    let program = Program(p)
    return (session(p, program) != nil ? .session : .user, program)
  }

  /// Why a process is never signalled from Bollard, or nil when it may be.
  public static func protection(_ p: Proc) -> String? {
    if p.pid <= 1 || p.base == "launchd" { return "launchd" }
    if p.pid == getpid() { return "Bollard itself" }
    if ownAncestors.contains(p.pid) { return "the process Bollard is running under" }
    if p.uid != getuid() { return "a process owned by another user" }
    if systemPath(p.path) { return "a macOS system process" }
    if agent(p) != nil { return nil }
    if terminalApps.contains(where: { p.path.contains($0) }), !p.path.contains(".framework/") {
      return "a terminal or editor"
    }
    if p.args.contains(where: {
      $0.contains("org.prismlauncher.EntryPoint") || $0.contains("net.minecraft.client")
        || $0.contains("KnotClient")
    }) {
      return "a game client"
    }
    return session(p, Program(p))
  }
  public static func protected(_ p: Proc) -> Bool { protection(p) != nil }

  /// The processes a Stop signals, and the protected ones inside the tree it leaves alone.
  ///
  /// For an agent that is the agent and the helpers it started directly, such as MCP servers. What
  /// the agent ran through a shell is a workload of its own and keeps running.
  public static func killSet(_ root: Int32, _ all: [Int32: Proc]) -> (
    members: [Proc], excluded: [Proc]
  ) {
    killSet(root, all, children: Dictionary(grouping: all.values, by: \.parent))
  }
  static func killSet(_ root: Int32, _ all: [Int32: Proc], children: [Int32: [Proc]]) -> (
    members: [Proc], excluded: [Proc]
  ) {
    var members: [Proc] = []
    var excluded: [Proc] = []
    var seen: Set<Int32> = []
    var pending = [root]
    while let id = pending.popLast() {
      guard seen.insert(id).inserted, let p = all[id] else { continue }
      let isAgent = agent(p) != nil
      if id != root {
        if protected(p) {
          excluded.append(p)
          continue
        }
        // An agent inside someone else's tree is its own row. Inside an agent's tree, only its
        // own subprocesses and direct helpers belong to it.
        let parentIsAgent = all[p.parent].map { agent($0) != nil } ?? false
        if isAgent, !parentIsAgent { continue }
        if parentIsAgent, !isAgent, shells.contains(p.base) { continue }
      }
      members.append(p)
      pending.append(contentsOf: (children[id] ?? []).map(\.pid))
    }
    return (members.sorted { $0.pid < $1.pid }, excluded.sorted { $0.pid < $1.pid })
  }

  /// One listener per socket. A socket inherited across fork is held by a whole family; it belongs
  /// to the holder whose parent does not hold it, which is the process that opened it.
  public static func owners(_ held: [Listener], in all: [Int32: Proc]) -> [Listener] {
    Dictionary(grouping: held, by: \.socket).values.compactMap { holders in
      let pids = Set(holders.map(\.pid))
      let top = holders.filter { !pids.contains(all[$0.pid]?.parent ?? -1) }
      return (top.isEmpty ? holders : top).min { $0.pid < $1.pid }
    }.sorted { ($0.port, $0.address, $0.path, $0.pid) < ($1.port, $1.address, $1.path, $1.pid) }
  }

  public static func workloads(
    _ all: [Int32: Proc], listeners: [Listener], labels: [Int32: String] = [:],
    orphans: Set<Identity> = [], now: Double = Date().timeIntervalSince1970,
    checkout: (String) -> Checkout? = Git.checkout
  ) -> [Workload] {
    let me = getuid()
    var sockets: [Int32: [Listener]] = [:]
    for l in listeners { sockets[l.pid, default: []].append(l) }
    let children = Dictionary(grouping: all.values, by: \.parent)
    var roles: [Int32: Role] = [:]
    var programs: [Int32: Program] = [:]
    for p in all.values where p.uid == me && !p.zombie {
      let found = role(p, in: all)
      roles[p.pid] = found.role
      programs[p.pid] = found.program
    }
    func isAgent(_ pid: Int32) -> Bool {
      if case .agent = roles[pid] { return true }
      return false
    }
    func sorted(_ listeners: [Listener]) -> [Listener] {
      Array(Set(listeners)).sorted {
        ($0.transport.rawValue, $0.port, $0.address, $0.path) < (
          $1.transport.rawValue, $1.port, $1.address, $1.path
        )
      }
    }
    var result: [Identity: Workload] = [:]
    var userRoots = Set<Int32>()

    for p in all.values.sorted(by: { $0.pid < $1.pid }) {
      guard let role = roles[p.pid] else { continue }
      let tcp = (sockets[p.pid] ?? []).filter { $0.transport == .tcp }
      switch role {
      case .user:
        var root = p
        var seen: Set<Int32> = [p.pid]
        while let parent = all[root.parent], roles[parent.pid] == .user,
          seen.insert(parent.pid).inserted
        {
          root = parent
        }
        // Started directly by an agent, not through its shell: a helper, listed with the agent.
        if isAgent(root.parent), !shells.contains(root.base) { continue }
        userRoots.insert(root.pid)

      case .agent(let name):
        guard !isAgent(p.parent) else { continue }
        let set = killSet(p.pid, all, children: children)
        let helpers = (children[p.pid] ?? []).filter {
          roles[$0.pid] == .user && !shells.contains($0.base)
        }
        let place = project(p, program: nil, label: nil, checkout: checkout)
        var row = Workload(
          root: p, members: set.members, excluded: set.excluded,
          kind: Kind(name: name, icon: "sparkles"), name: place.name,
          detail: helpers.isEmpty
            ? name : "\(helpers.count) helper\(helpers.count == 1 ? "" : "s")",
          listeners: sorted(set.members.flatMap { sockets[$0.pid] ?? [] }),
          provenance: provenance(of: p, in: all, labels: labels),
          origin: origin(of: p, in: all, labels: labels), orphan: false, section: .agents,
          cautions: [
            "Ends the agent session and the helpers it started. Servers it launched keep running."
          ],
          blocked: protection(p).map { "Bollard never quits \($0)." }, launchdLabel: labels[p.pid])
        row.branch = place.branch
        result[p.identity] = row

      case .app(let bundle):
        guard !tcp.isEmpty else { continue }
        // Promote to the application's main process so one row owns every helper's port.
        var root = p
        while let parent = all[root.parent], parent.outerBundle == bundle, !protected(parent) {
          root = parent
        }
        let blocked = protection(root)
        let set =
          blocked == nil
          ? killSet(root.pid, all, children: children) : (members: [Proc](), excluded: [Proc]())
        let own = set.members.flatMap { sockets[$0.pid] ?? [] }.filter { $0.transport == .tcp }
        result[root.identity] = Workload(
          root: root, members: set.members, excluded: set.excluded,
          kind: Kind(name: "App", icon: "app.dashed", web: true), name: appName(bundle),
          listeners: sorted((result[root.identity]?.listeners ?? []) + own + tcp),
          provenance: provenance(of: root, in: all, labels: labels),
          origin: origin(of: root, in: all, labels: labels), orphan: false,
          section: bundle.hasPrefix("/System/") ? .system : .apps, cautions: [],
          blocked: blocked.map { "Bollard never quits \($0)." }, launchdLabel: labels[root.pid])

      case .system, .session:
        guard !tcp.isEmpty else { continue }
        result[p.identity] = Workload(
          root: p, members: [], excluded: [], kind: Kind(name: p.comm, icon: "lock"), name: p.comm,
          listeners: sorted(tcp), provenance: provenance(of: p, in: all, labels: labels),
          origin: origin(of: p, in: all, labels: labels), orphan: false, section: .system,
          cautions: [],
          blocked: "Bollard never quits \(protection(p) ?? "a macOS system process").",
          launchdLabel: labels[p.pid])
      }
    }

    let home = NSHomeDirectory()
    for pid in userRoots.sorted() {
      guard let root = all[pid] else { continue }
      let set = killSet(pid, all, children: children)
      let held = sorted(set.members.flatMap { sockets[$0.pid] ?? [] })
      let reachable = held.contains { $0.transport != .unix }
      let label = labels[pid]
      let apple = label.map { $0.hasPrefix("com.apple.") || $0.hasPrefix("com.openssh.") } ?? false
      if !reachable {
        // Quiet trees that are not the user's own work: one-shot commands, Apple's launch agents
        // and the background helpers applications install under a Library folder.
        if now - Double(root.identity.start) / 1e6 < settleTime { continue }
        // Started directly by an application: its helper, such as an editor's language server.
        if case .app = roles[root.parent], !shells.contains(root.base) { continue }
        if apple || root.path.hasPrefix("/Library/") || root.path.hasPrefix(home + "/Library/") {
          continue
        }
        // A daemon a toolchain leaves behind, such as Xcode's ibtoold. Its interpreters are
        // different: /usr/bin/python3 is Xcode's Python, and what it runs is the user's.
        if root.parent == 1, label == nil, root.path.contains(".app/Contents/Developer/"),
          programs[pid]?.runtime == nil
        {
          continue
        }
      }
      // Look through wrappers to the process that does the work.
      var lead = root
      while programs[lead.pid]?.wrapper == true {
        let next = (children[lead.pid] ?? []).filter { roles[$0.pid] == .user }
        guard next.count == 1 else { break }
        lead = next[0]
      }
      let program = programs[lead.pid] ?? Program(lead)
      var kind = Kinds.known(program, lead)
      if kind == nil {
        // A script or wrapper that fans out: name the tree after a member that is recognised,
        // a listening one first. Utilities that only keep a job company do not name it.
        let recognised = set.members.compactMap { member -> (Proc, Kind)? in
          guard let known = programs[member.pid].flatMap({ Kinds.known($0, member) }),
            !["Keep awake", "Log tail"].contains(known.name)
          else { return nil }
          return (member, known)
        }
        kind = (recognised.first { !(sockets[$0.0.pid] ?? []).isEmpty } ?? recognised.first)?.1
      }
      var type = kind ?? Kinds.fallback(program, lead)
      if kind == nil, held.contains(where: { $0.transport == .tcp }) { type.web = true }
      let place = project(lead, program: program, label: label, checkout: checkout)
      let orphan = orphans.contains(root.identity) && root.parent == 1 && label == nil
      var cautions: [String] = []
      if let label {
        cautions.append(
          label.hasPrefix("homebrew.mxcl.")
            ? "Homebrew service \(label.dropFirst(14)). Stopping it with brew keeps it from restarting."
            : "Managed by launchd as \(label). launchd may restart it; Unload stops it for good.")
      }
      if !set.excluded.isEmpty {
        cautions.append(
          "Leaves running: " + set.excluded.map { "\($0.base) (\($0.pid))" }.joined(separator: ", ")
        )
      }
      if set.members.contains(where: { $0.suspended }) {
        cautions.append("A suspended process will be resumed before it is stopped.")
      }
      let controller = Controllers.match(root)
      if type.name == "Minecraft", controller == nil {
        cautions.append("Stop lets the server save on shutdown. Force Quit skips saving.")
      }
      var row = Workload(
        root: root, members: set.members, excluded: set.excluded, kind: type, name: place.name,
        detail: program.summary, lead: lead, listeners: held,
        provenance: provenance(of: root, in: all, labels: labels),
        origin: origin(of: root, in: all, labels: labels), orphan: orphan,
        section: apple ? .system : reachable ? .servers : .background, cautions: cautions,
        blocked: nil, launchdLabel: label)
      row.branch = place.branch
      row.controller = controller
      if let controller { row.provenance = controller.label }
      if orphan { row.provenance = "Orphaned · observed parent exit" }
      result[root.identity] = row
    }

    // Remove nested rows; the containing workload owns metrics and actions.
    let values = Array(result.values)
    let order: [Lane: Int] = [.servers: 0, .background: 1, .agents: 2, .apps: 3, .system: 4]
    return values.filter { w in
      !values.contains { $0.id != w.id && $0.members.contains { $0.identity == w.id } }
    }.sorted {
      (order[$0.section]!, $0.name.lowercased(), $0.root.pid) < (
        order[$1.section]!, $1.name.lowercased(), $1.root.pid
      )
    }
  }

  /// The project a process belongs to: its repository, else its directory, else the script's
  /// folder for jobs launchd starts in `/`, else the launchd label or the program itself.
  static func project(
    _ p: Proc, program: Program?, label: String?, checkout: (String) -> Checkout?
  ) -> (name: String, branch: String?) {
    func placeless(_ directory: String) -> Bool {
      directory.isEmpty || directory == "/" || directory == NSHomeDirectory()
    }
    var directory = p.cwd
    if placeless(directory), let script = program?.script, script.hasPrefix("/") {
      directory = URL(fileURLWithPath: script).deletingLastPathComponent().path
    }
    if let found = checkout(directory) { return (found.name, found.branch) }
    if !placeless(directory) { return (URL(fileURLWithPath: directory).lastPathComponent, nil) }
    return (label ?? program?.target ?? p.comm, nil)
  }
  static func bundle(_ p: Proc, in all: [Int32: Proc]) -> String? {
    if let bundle = p.appBundle { return bundle }
    guard let outer = p.outerBundle, let parent = all[p.parent], parent.outerBundle == outer else {
      return nil
    }
    return outer
  }
  static func appName(_ bundle: String) -> String {
    String(URL(fileURLWithPath: bundle).lastPathComponent.dropLast(4))
  }
  static let launchers = [
    ("Visual Studio Code.app", "VS Code"), ("Zed.app", "Zed"), ("Cursor.app", "Cursor"),
    ("Xcode.app", "Xcode"), ("Terminal.app", "Terminal"), ("iTerm.app", "iTerm"),
    ("Ghostty.app", "Ghostty"), ("Warp.app", "Warp"),
  ]
  /// The launcher a process is, if it is one: an agent, an editor or a terminal.
  static func launcher(_ p: Proc) -> String? {
    if let name = agent(p) { return name }
    if p.path.contains("/ChatGPT.app/") { return "Codex" }
    if p.path.contains("/Claude.app/") { return "Claude Code" }
    return launchers.first { p.path.contains($0.0) }?.1
  }
  /// Who launched it, for the origin filter: an agent, an editor, a terminal, launchd or Detached.
  static func origin(of root: Proc, in all: [Int32: Proc], labels: [Int32: String]) -> String {
    if labels[root.pid] != nil { return "launchd" }
    var ancestor = root.parent
    var visited = Set<Int32>()
    var shell = false
    while let a = all[ancestor], visited.insert(ancestor).inserted {
      if let name = launcher(a) { return name }
      if shells.contains(a.base) || a.named(sessions) { shell = true }
      ancestor = a.parent
    }
    // The parents are gone, but macOS still knows whose work this is.
    if root.responsible != root.pid, let owner = all[root.responsible], let name = launcher(owner) {
      return name
    }
    return shell ? "Terminal" : (root.parent == 1 ? "Detached" : "Other")
  }
  /// The same lineage in words, for the detail view.
  static func provenance(of root: Proc, in all: [Int32: Proc], labels: [Int32: String]) -> String {
    if let label = labels[root.pid] { return "launchd · \(label)" }
    let origin = origin(of: root, in: all, labels: labels)
    switch origin {
    case "Detached": return "Detached · launch origin unknown"
    case "Other": return "Parent PID \(root.parent)"
    case "Terminal":
      var ancestor = root.parent
      var visited = Set<Int32>()
      while let a = all[ancestor], visited.insert(ancestor).inserted {
        if shells.contains(a.base) { return "Terminal · \(a.base)" }
        ancestor = a.parent
      }
      return origin
    default: return origin
    }
  }

  /// Confirms the workload still describes live processes and returns the current kill set,
  /// including descendants spawned since the scan.
  @discardableResult
  public static func validate(_ w: Workload, live: [Int32: Proc]) throws -> [Proc] {
    if let blocked = w.blocked { throw SafetyError(blocked) }
    if w.controller != nil && Controllers.match(w.root) == nil {
      throw SafetyError("The declared controller script changed. Refusing to signal it.")
    }
    guard let root = live[w.root.pid], root.identity == w.root.identity else {
      throw SafetyError("\(w.name) already exited or its PID was reused.")
    }
    if let reason = protection(root) { throw SafetyError("Bollard never quits \(reason).") }
    let current = killSet(root.pid, live).members
    // Members that exited are fine; a reused PID carries a new identity and is never signalled.
    for old in w.members {
      guard let now = live[old.pid], now.identity == old.identity else { continue }
      guard now.path == old.path, now.args == old.args, now.uid == old.uid else {
        throw SafetyError("Process \(old.pid) changed identity or command. Refresh and try again.")
      }
    }
    return current
  }
}

public struct SafetyError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
