import Foundation

public enum Policy {
  static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
  static let agents: Set<String> = [
    "codex", "claude", "aider", "hermes", "gemini", "opencode", "cursor-agent",
  ]
  static let sessions: Set<String> = ["ssh", "sshd", "tmux", "screen", "login", "launchd", "sudo"]
  static let terminalApps = [
    "/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/Warp.app/", "/ChatGPT.app/",
    "/Visual Studio Code.app/", "/Zed.app/", "/Cursor.app/", "/Xcode.app/", "/Claude.app/",
  ]
  static let toolPatterns = [
    "mcp", "language-server", "languageserver", "tsserver", "ipykernel", "jupyter-lsp",
    "gradledaemon", "kotlincompiledaemon", "node_repl", "trusted-worker.js", "hermes.cli",
    "codex app-server", "resource-tracker", "multiprocessing.resource_tracker", "copilot",
  ]

  /// Why a process is never signalled from DevPorts, or nil when it may be.
  public static func protection(_ p: Proc) -> String? {
    if p.pid <= 1 || p.base == "launchd" { return "launchd" }
    if p.pid == getpid() { return "DevPorts itself" }
    if p.uid != getuid() { return "owned by another user" }
    let path = p.path.lowercased()
    if path.hasPrefix("/system/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
      || path.hasPrefix("/sbin/") || path.hasPrefix("/library/apple/")
    {
      return "a macOS system process"
    }
    if terminalApps.contains(where: { p.path.has($0) }), !p.path.has(".framework/") {
      return "a terminal or editor"
    }
    if p.named(agents) { return "a coding agent" }
    if p.named(sessions) { return "a login or session process" }
    let text = p.text
    if text.has("org.prismlauncher.entrypoint") || text.has("net.minecraft.client")
      || text.has("knotclient")
    {
      return "a game client"
    }
    if shells.contains(p.base), interactiveShell(p) { return "an interactive shell" }
    if ["hermes.cli", "aider"].contains(where: { text.has($0) }) && p.base.hasPrefix("python") {
      return "a coding agent"
    }
    return nil
  }
  public static func protected(_ p: Proc) -> Bool { protection(p) != nil }
  /// Helpers that belong to an agent, editor or notebook. Visible, but stopped from their owner.
  public static func tool(_ p: Proc) -> Bool {
    let text = p.text
    return toolPatterns.contains { text.has($0) }
  }
  static func interactiveShell(_ p: Proc) -> Bool {
    shells.contains(p.base)
      && !p.args.dropFirst().contains(where: { $0.hasPrefix("-") && $0.contains("c") })
  }
  static func simpleWrapper(_ p: Proc) -> Bool {
    guard shells.contains(p.base), p.args.count == 3, ["-c", "-lc"].contains(p.args[1]) else {
      return false
    }
    let s = p.args[2]
    return !s.contains(where: { ";|\n`$<>(){}".contains($0) })
  }
  /// Package-manager and shell wrappers that exist only to run their single child.
  static func wrapper(_ p: Proc) -> Bool {
    if simpleWrapper(p) { return true }
    if p.base == "node", p.args.count >= 2 {
      let script = URL(fileURLWithPath: p.args[1]).lastPathComponent
      if ["npm-cli.js", "pnpm.cjs", "pnpm.js", "yarn.js"].contains(script), p.args.count >= 3,
        ["run", "start", "dev", "exec", "run-script"].contains(p.args[2])
      {
        return true
      }
      if ["tsx", "ts-node", "nodemon", "turbo", "concurrently"].contains(script) { return true }
      if p.has("tsx/dist/preflight") || p.has("ts-node/") { return true }
    }
    let a = p.text
    if [
      "npm", "pnpm", "yarn", "bun", "bunx", "npx", "uv", "uvx", "poetry", "pipenv", "cargo", "make",
    ].contains(p.base)
      && (a.has(" run") || a.has(" dev") || a.has(" start") || a.has(" exec") || a.has(" x "))
    {
      return true
    }
    return ["caffeinate", "nice", "time", "env", "nohup", "setsid", "stdbuf"].contains(p.base)
  }
  /// A parent that will not respawn its child when the child exits.
  static func launchBoundary(_ p: Proc) -> Bool {
    if p.pid == 1 || protected(p) || wrapper(p) { return true }
    if shells.contains(p.base), p.args.count == 3 {
      let command = p.args[2]
      if command.contains("while") || command.contains("until") || command.contains("for ") {
        return false
      }
      return !command.contains(where: { "|;`$<>(){}".contains($0) })
    }
    return false
  }

  public static func kind(_ p: Proc, listening: Bool) -> Kind? {
    let s = p.text
    func k(_ name: String, _ icon: String = "terminal", _ web: Bool = true, _ bg: Bool = false)
      -> Kind
    { Kind(name: name, icon: icon, web: web, background: bg) }
    if s.has("net.minecraft.server") || s.has("fabric-server") || s.has("paper-")
      || (p.base == "java" && s.has("nogui") && s.has(".jar"))
    {
      return k("Minecraft", "cube", false)
    }
    if p.base == "ollama" || s.hasPrefix("ollama ") { return k("Ollama", "sparkles", false) }
    if s.has("llama-server") || s.has("mlx_lm.server") || s.has("vllm")
      || s.has("lms server") || s.has("lm studio")
    {
      return k("AI service", "sparkles")
    }
    if s.has("jupyter") && (s.has("lab") || s.has("notebook") || s.has("server")) {
      return k("Jupyter", "book.closed")
    }
    if s.has("next-server") || s.has("next dev") || s.has("next start") || s.has("/next/") {
      return k("Next.js", "globe")
    }
    if s.has("nuxt") { return k("Nuxt", "globe") }
    if s.has("remix") { return k("Remix", "globe") }
    if s.has("astro") { return k("Astro", "globe") }
    if s.has("svelte") { return k("SvelteKit", "globe") }
    if s.has("vite") { return k("Vite", "bolt") }
    if s.has("webpack") { return k("Webpack", "shippingbox") }
    if s.has("storybook") { return k("Storybook", "book") }
    if s.has("wrangler") || p.base == "workerd" { return k("Wrangler", "cloud") }
    if s.has("uvicorn") { return k("Uvicorn", "network") }
    if s.has("gunicorn") { return k("Gunicorn", "network") }
    if s.has("hypercorn") { return k("Hypercorn", "network") }
    if s.has("http.server") { return k("Python HTTP", "globe") }
    if s.has("flask") { return k("Flask", "network") }
    if s.has("manage.py runserver") { return k("Django", "network") }
    if s.has("fastapi") { return k("FastAPI", "network") }
    if s.has("streamlit") { return k("Streamlit", "chart.bar") }
    if s.has("rails ") || s.has("puma") { return k("Rails", "network") }
    if s.has("php artisan") || s.has("php -s") { return k("PHP", "network") }
    if [
      "postgres", "redis-server", "mysqld", "mongod", "mariadbd", "clickhouse", "meilisearch",
      "typesense",
    ].contains(p.base) {
      let names = [
        "postgres": "PostgreSQL", "redis-server": "Redis", "mysqld": "MySQL", "mongod": "MongoDB",
        "mariadbd": "MariaDB", "clickhouse": "ClickHouse", "meilisearch": "Meilisearch",
        "typesense": "Typesense",
      ]
      return k(names[p.base] ?? p.base, "externaldrive", false)
    }
    if ["nginx", "caddy", "httpd", "traefik"].contains(p.base) {
      return k(p.base.capitalized, "globe")
    }
    if s.has("--watch") || s.has("nodemon") || s.has("watchfiles") || s.has("watchexec")
      || s.has("chokidar")
    {
      return k("Watcher", "eye", false, true)
    }
    if s.has("celery") || s.has("sidekiq") || s.has("rq worker") || s.has("bullmq")
      || s.has("temporal")
    {
      return k("Worker", "gearshape.2", false, true)
    }
    if s.has("cloudflared") || s.has("ngrok") || s.has("tailscale serve") {
      return k("Tunnel", "arrow.left.arrow.right", false, true)
    }
    let runtime = [
      "node": "Node.js", "bun": "Bun", "deno": "Deno", "python": "Python", "python3": "Python",
      "java": "Java", "ruby": "Ruby", "php": "PHP", "go": "Go", "dotnet": ".NET",
      "elixir": "Elixir", "beam.smp": "Erlang",
    ]
    let language = runtime.first { p.base.hasPrefix($0.key) }?.value
    if listening {
      return k(language ?? p.comm, "network", true)
    }
    // Explicit user script, not an arbitrary process with a familiar executable.
    if language != nil,
      p.args.dropFirst().contains(where: {
        $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".mjs") || $0.hasSuffix(".ts")
          || $0.hasSuffix(".rb")
      }), !p.cwd.isEmpty, !p.cwd.contains("/Library/"), !s.has("node_modules/")
    {
      return k("Script", "terminal", false, true)
    }
    return nil
  }

  public static func descendants(_ root: Int32, _ all: [Int32: Proc]) -> [Proc] {
    let children = Dictionary(grouping: all.values, by: \.parent)
    var ids: Set<Int32> = []
    var pending = [root]
    while let id = pending.popLast() {
      if ids.insert(id).inserted { pending.append(contentsOf: (children[id] ?? []).map(\.pid)) }
    }
    return ids.compactMap { all[$0] }.sorted { $0.pid < $1.pid }
  }
  /// The root's tree split into what Stop signals and what it leaves alone.
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
      if id != root, protected(p) {
        excluded.append(p)
        continue
      }
      members.append(p)
      pending.append(contentsOf: (children[id] ?? []).map(\.pid))
    }
    return (members.sorted { $0.pid < $1.pid }, excluded.sorted { $0.pid < $1.pid })
  }

  public static func workloads(
    _ all: [Int32: Proc], listeners: [Listener], labels: [Int32: String] = [:],
    orphans: Set<Identity> = []
  ) -> [Workload] {
    let me = getuid()
    var byPid: [Int32: [Listener]] = [:]
    for l in listeners { byPid[l.pid, default: []].append(l) }
    let children = Dictionary(grouping: all.values, by: \.parent)
    let childCounts = children.mapValues(\.count)
    var result: [Identity: Workload] = [:]
    for p in all.values.sorted(by: { $0.pid < $1.pid }) where !p.zombie {
      let own = byPid[p.pid] ?? []
      let listening = !own.isEmpty
      if p.uid != me {
        guard listening else { continue }
        result[p.identity] = Workload(
          root: p, members: [], excluded: [], kind: Kind(name: p.comm, icon: "lock", web: false),
          name: p.comm.isEmpty ? "PID \(p.pid)" : p.comm, listeners: own,
          provenance: p.uid == 0 ? "root" : "user \(p.uid)", orphan: false, section: .system,
          cautions: [], blocked: "Owned by another user.", launchdLabel: nil)
        continue
      }
      let type: Kind
      if let reason = protection(p) {
        guard listening else { continue }
        type = Kind(name: p.comm, icon: "lock", web: false)
        var row = Workload(
          root: p, members: [], excluded: [], kind: type,
          name: bundle(p, in: all).map(appName) ?? p.comm,
          listeners: own, provenance: "", orphan: false,
          section: bundle(p, in: all) != nil && !p.path.hasPrefix("/System/") ? .apps : .system,
          cautions: [], blocked: "DevPorts never quits \(reason).", launchdLabel: labels[p.pid])
        row.provenance = provenance(of: p, in: all, labels: labels)
        result[p.identity] = row
        continue
      }
      if tool(p) {
        guard listening else { continue }
        let row = Workload(
          root: p, members: [], excluded: [],
          kind: Kind(name: "Tool", icon: "wrench.and.screwdriver", web: false),
          name: URL(fileURLWithPath: p.cwd).lastPathComponent, listeners: own,
          provenance: provenance(of: p, in: all, labels: labels), orphan: false, section: .system,
          cautions: [],
          blocked: "A helper owned by an agent, editor or notebook. Stop it from its owner.",
          launchdLabel: labels[p.pid])
        result[p.identity] = row
        continue
      }
      if let bundle = bundle(p, in: all) {
        guard listening else { continue }
        // Promote to the application's main process so one row owns every helper's port.
        var root = p
        while let parent = all[root.parent], parent.outerBundle == bundle, !protected(parent) {
          root = parent
        }
        let set = killSet(root.pid, all, children: children)
        var row = Workload(
          root: root, members: set.members, excluded: set.excluded,
          kind: Kind(name: "App", icon: "app.dashed", web: true), name: appName(bundle),
          listeners: set.members.flatMap { byPid[$0.pid] ?? [] },
          provenance: provenance(of: root, in: all, labels: labels),
          orphan: false, section: .apps, cautions: [], blocked: nil, launchdLabel: labels[root.pid])
        if let existing = result[root.identity] {
          row.listeners = existing.listeners + row.listeners
        }
        row.listeners = Array(Set(row.listeners)).sorted {
          ($0.port, $0.address) < ($1.port, $1.address)
        }
        result[root.identity] = row
        continue
      }
      guard let detected = kind(p, listening: listening) else { continue }
      type = detected
      var root = p
      var seen: Set<Int32> = [p.pid]
      while let parent = all[root.parent], !seen.contains(parent.pid), !protected(parent),
        wrapper(parent), parent.cwd == root.cwd || parent.cwd.isEmpty, childCounts[parent.pid] == 1
      {
        seen.insert(parent.pid)
        root = parent
      }
      if type.name == "Minecraft", let parent = all[root.parent],
        LocalControllers.isMinecraftController(parent)
      {
        root = parent
      }
      let set = killSet(root.pid, all, children: children)
      let memberListeners = Array(Set(set.members.flatMap { byPid[$0.pid] ?? [] })).sorted {
        ($0.port, $0.address) < ($1.port, $1.address)
      }
      if memberListeners.isEmpty && !type.background { continue }
      if type.name == "Script",
        set.members.contains(where: { $0.pid != root.pid && !(byPid[$0.pid] ?? []).isEmpty })
      {
        continue
      }
      let label = labels[root.pid]
      let orphan = orphans.contains(root.identity) && root.parent == 1 && label == nil
      let name = URL(fileURLWithPath: root.cwd).lastPathComponent
      var cautions: [String] = []
      if let label {
        cautions.append(
          label.hasPrefix("homebrew.mxcl.")
            ? "Homebrew service \(label.dropFirst(14)). Stopping it with brew keeps it from restarting."
            : "Managed by launchd as \(label). launchd may restart it; Unload stops it for good.")
      } else if let parent = all[root.parent], root.parent != 1, !launchBoundary(parent) {
        let command = parent.args.joined(separator: " ")
        cautions.append(
          "Its parent \(parent.base) (PID \(parent.pid)) keeps running and may restart it: \(command.prefix(80))"
        )
      }
      if !set.excluded.isEmpty {
        cautions.append(
          "Leaves running: " + set.excluded.map { "\($0.base) (\($0.pid))" }.joined(separator: ", ")
        )
      }
      if set.members.contains(where: { $0.suspended }) {
        cautions.append("A suspended process will be resumed before it is stopped.")
      }
      if type.name == "Minecraft", !LocalControllers.isMinecraftController(root) {
        cautions.append("Stop lets the server save on shutdown. Force Quit skips saving.")
      }
      var row = Workload(
        root: root, members: set.members, excluded: set.excluded, kind: type,
        name: name.isEmpty || name == "/" ? type.name.lowercased() : name,
        listeners: memberListeners,
        provenance: provenance(of: root, in: all, labels: labels), orphan: orphan,
        section: memberListeners.isEmpty ? .background : .servers, cautions: cautions, blocked: nil,
        launchdLabel: label)
      row.usesMinecraftController = LocalControllers.isMinecraftController(root)
      if row.usesMinecraftController {
        row.provenance = "Minecraft controller · saves world and backs up"
      }
      if orphan { row.provenance = "Orphaned · observed parent exit" }
      if type.name == "Ollama" { row.name = "ollama" }
      if type.name == "Minecraft" {
        row.name = name.replacingOccurrences(
          of: "-[0-9]{10,}$", with: "", options: .regularExpression
        )
        .replacingOccurrences(of: "-", with: " ")
      }
      if let existing = result[root.identity], !existing.kind.background { continue }
      result[root.identity] = row
    }
    // Remove nested rows; the containing workload owns metrics and actions.
    let values = Array(result.values)
    let order: [Lane: Int] = [.servers: 0, .background: 1, .apps: 2, .system: 3]
    return values.filter { w in
      !values.contains { $0.id != w.id && $0.members.contains { $0.identity == w.id } }
    }.sorted {
      (order[$0.section]!, $0.name.lowercased(), $0.root.pid) < (
        order[$1.section]!, $1.name.lowercased(), $1.root.pid
      )
    }
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
  static func provenance(of root: Proc, in all: [Int32: Proc], labels: [Int32: String]) -> String {
    var provenance =
      labels[root.pid].map { "launchd · \($0)" }
      ?? (root.parent == 1 ? "Detached · launch origin unknown" : "Parent PID \(root.parent)")
    var ancestor = root.parent
    var visited = Set<Int32>()
    while let a = all[ancestor], visited.insert(ancestor).inserted {
      if a.base.contains("codex") || a.path.contains("ChatGPT.app") {
        provenance = "Codex"
        break
      }
      if a.base == "claude" || a.argName == "claude" || a.path.has("/Claude.app/") {
        provenance = "Claude Code"
        break
      }
      if a.named(agents) {
        provenance = (agents.contains(a.base) ? a.base : a.argName).capitalized
        break
      }
      if shells.contains(a.base) { provenance = "Terminal · \(a.base)" }
      for (marker, name) in [
        ("Terminal.app", "Terminal"), ("Visual Studio Code.app", "Visual Studio Code"),
        ("Zed.app", "Zed"),
        ("Cursor.app", "Cursor"), ("iTerm.app", "iTerm"), ("Ghostty.app", "Ghostty"),
        ("Warp.app", "Warp"),
        ("Xcode.app", "Xcode"),
      ] where a.path.contains(marker) {
        return provenance.hasPrefix("Terminal · ") && name == "Terminal" ? provenance : name
      }
      ancestor = a.parent
    }
    return provenance
  }

  /// Confirms the workload still describes live processes and returns the current kill set,
  /// including descendants spawned since the scan.
  @discardableResult
  public static func validate(_ w: Workload, live: [Int32: Proc]) throws -> [Proc] {
    if let blocked = w.blocked { throw SafetyError(blocked) }
    if w.usesMinecraftController && !LocalControllers.isMinecraftController(w.root) {
      throw SafetyError("Audited Minecraft controller changed. Refusing to signal it.")
    }
    guard let root = live[w.root.pid], root.identity == w.root.identity else {
      throw SafetyError("\(w.name) already exited or its PID was reused.")
    }
    if let reason = protection(root) { throw SafetyError("DevPorts never quits \(reason).") }
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
