import Foundation

public enum Policy {
  static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
  public static func protected(_ p: Proc) -> Bool {
    let path = p.path.lowercased()
    let tokens = p.args.map { $0.lowercased() }
    let text = tokens.joined(separator: " ")
    if p.pid <= 1 || p.pid == getpid() || p.uid != getuid() || path.hasPrefix("/system/")
      || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    {
      return true
    }
    let ollamaService =
      p.base == "ollama" && p.args.dropFirst().first == "serve"
      && path.hasPrefix("/applications/ollama.app/contents/")
    if path.contains(".app/") && !path.contains("/python.framework/") && !ollamaService {
      return true
    }
    if text.contains("org.prismlauncher.entrypoint") || text.contains("net.minecraft.client")
      || text.contains("knotclient")
    {
      return true
    }
    if shells.contains(p.base) { return !simpleWrapper(p) }
    if [
      "codex", "claude", "aider", "hermes", "gemini", "opencode", "ssh", "sshd", "tmux", "screen",
      "login", "launchd", "sudo", "docker", "containerd", "com.docker.backend",
    ].contains(p.base) {
      return true
    }
    return [
      "mcp", "language-server", "languageserver", "tsserver", "ipykernel", "jupyter-lsp",
      "gradledaemon", "kotlincompiledaemon", "node_repl", "trusted-worker.js", "hermes.cli",
      "aider", "codex app-server", "resource-tracker", "multiprocessing.resource_tracker",
    ].contains { text.contains($0) }
  }
  static func simpleWrapper(_ p: Proc) -> Bool {
    guard shells.contains(p.base), p.args.count == 3, p.args[1] == "-c" else { return false }
    let s = p.args[2]
    return !s.contains(where: { ";&|\n`$<>()".contains($0) })
      && ["next ", "vite ", "node ", "python ", "python3 ", "uvicorn ", "tsc ", "nodemon "].contains
      { s.hasPrefix($0) }
  }
  static func wrapper(_ p: Proc) -> Bool {
    if simpleWrapper(p) { return true }
    if p.base == "node", p.args.count >= 3,
      ["npm-cli.js", "pnpm.cjs", "pnpm.js", "yarn.js"].contains(
        URL(fileURLWithPath: p.args[1]).lastPathComponent),
      ["run", "start", "dev", "exec"].contains(p.args[2])
    {
      return true
    }
    let a = p.args.joined(separator: " ").lowercased()
    return ["npm", "pnpm", "yarn", "bun"].contains(p.base)
      && (a.contains(" run ") || a.contains(" dev") || a.contains(" start"))
      || a.hasPrefix("npm run ") || a.hasPrefix("npm exec ") || a.hasPrefix("npm start")
  }
  static func launchBoundary(_ p: Proc) -> Bool {
    if shells.contains(p.base) {
      let command = p.args.dropFirst().joined(separator: " ")
      if command.range(of: "\\b(while|until|for|repeat|trap)\\b", options: .regularExpression)
        != nil
      {
        return false
      }
      // Shell scripts may be persistent supervisors. Interactive shells are boundaries.
      if p.args.dropFirst().contains(where: { !$0.hasPrefix("-") })
        && !p.args.contains(where: { $0.hasPrefix("-") && $0.contains("c") })
      {
        return false
      }
      return true
    }
    if ["codex", "claude", "aider", "hermes", "gemini", "opencode"].contains(p.base) {
      return true
    }
    return [
      "/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/Warp.app/", "/ChatGPT.app/",
      "/Visual Studio Code.app/", "/Zed.app/",
    ].contains { p.path.contains($0) }
  }
  public static func kind(_ p: Proc, listening: Bool) -> Kind? {
    guard !protected(p) else { return nil }
    let s = p.args.joined(separator: " ").lowercased()
    func k(_ name: String, _ icon: String = "terminal", _ web: Bool = true, _ bg: Bool = false)
      -> Kind
    { Kind(name: name, icon: icon, web: web, background: bg) }
    if s.contains("net.minecraft.server") || s.contains("fabric-server") || s.contains("paper-")
      || (p.base == "java" && s.contains("nogui") && s.contains(".jar"))
    {
      return k("Minecraft", "cube", false)
    }
    if s.contains("ollama") { return k("Ollama", "sparkles", false) }
    if s.contains("llama-server") || s.contains("mlx_lm.server") || s.contains("vllm") {
      return k("AI service", "sparkles")
    }
    if s.contains("jupyter")
      && (s.contains("lab") || s.contains("notebook") || s.contains("server"))
    {
      return k("Jupyter", "book.closed")
    }
    if s.contains("next-server") || s.contains("next dev") || s.contains("next start")
      || s.contains("/next/")
    {
      return k("Next.js", "globe")
    }
    if s.contains("vite") { return k("Vite", "bolt") }
    if s.contains("uvicorn") { return k("Uvicorn", "network") }
    if s.contains("gunicorn") { return k("Gunicorn", "network") }
    if s.contains("http.server") { return k("Python HTTP", "globe") }
    if s.contains("flask") || s.contains("manage.py runserver") {
      return k(s.contains("flask") ? "Flask" : "Django", "network")
    }
    if ["postgres", "redis-server", "mysqld", "mongod"].contains(p.base) {
      return k(
        [
          "postgres": "PostgreSQL", "redis-server": "Redis", "mysqld": "MySQL", "mongod": "MongoDB",
        ][p.base]!, "externaldrive", false)
    }
    if ["nginx", "caddy", "httpd"].contains(p.base) { return k(p.base.capitalized, "globe") }
    if s.contains("--watch") || s.contains("nodemon") || s.contains("watchfiles") {
      return k("Watcher", "eye", false, true)
    }
    if s.contains("celery") || s.contains("sidekiq") || s.contains("rq worker") {
      return k("Worker", "gearshape.2", false, true)
    }
    let runtime = [
      "node": "Node.js", "bun": "Bun", "deno": "Deno", "python": "Python", "python3": "Python",
      "java": "Java", "ruby": "Ruby", "php": "PHP",
    ]
    if listening, let name = runtime[p.base] { return k(name, "terminal", false) }
    // Explicit user script, not an arbitrary process with a familiar executable.
    if !listening, runtime[p.base] != nil,
      p.args.dropFirst().contains(where: {
        $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".mjs") || $0.hasSuffix(".rb")
      }), !p.cwd.isEmpty, !p.cwd.contains("/Library/"), !s.contains("node_modules/")
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
  public static func workloads(
    _ all: [Int32: Proc], ports: [Int32: [Int]], labels: [Int32: String] = [:],
    orphans: Set<Identity> = []
  ) -> [Workload] {
    var result: [Identity: Workload] = [:]
    let childCounts = Dictionary(grouping: all.values, by: \.parent).mapValues(\.count)
    for p in all.values.sorted(by: { $0.pid < $1.pid }) {
      guard p.status != 5, let type = kind(p, listening: !(ports[p.pid] ?? []).isEmpty) else {
        continue
      }
      var root = p
      var seen: Set<Int32> = [p.pid]
      while let parent = all[root.parent], !seen.contains(parent.pid), !protected(parent),
        wrapper(parent), parent.cwd == root.cwd, childCounts[parent.pid] == 1
      {
        seen.insert(parent.pid)
        root = parent
      }
      if type.name == "Minecraft", let parent = all[root.parent],
        LocalControllers.isMinecraftController(parent)
      {
        root = parent
      }
      let members = descendants(root.pid, all)
      let memberPorts = Array(Set(members.flatMap { ports[$0.pid] ?? [] })).sorted()
      if memberPorts.isEmpty && !type.background { continue }
      if type.name == "Script",
        members.contains(where: { $0.pid != root.pid && !(ports[$0.pid] ?? []).isEmpty })
      {
        continue
      }
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
        if a.base == "claude" {
          provenance = "Claude Code"
          break
        }
        if a.path.contains("Terminal.app") || shells.contains(a.base) {
          provenance = "Terminal · \(a.base)"
        }
        if a.path.contains("Visual Studio Code.app") {
          provenance = "Visual Studio Code"
          break
        }
        if a.path.contains("Zed.app") {
          provenance = "Zed"
          break
        }
        ancestor = a.parent
      }
      if LocalControllers.isMinecraftController(root) {
        provenance = "Minecraft controller · saves world and backs up"
      }
      let orphan = orphans.contains(root.identity) && root.parent == 1 && labels[root.pid] == nil
      if orphan { provenance = "Orphaned · observed parent exit" }
      let name = URL(fileURLWithPath: root.cwd).lastPathComponent
      var refusal: String?
      if members.contains(where: protected) {
        refusal = "This tree contains a protected shell, app, agent, or system process."
      } else if members.contains(where: { $0.status == 4 }) {
        refusal = "A process is already suspended or being debugged."
      } else if all[root.parent] == nil && root.parent != 1 {
        refusal = "Parent identity could not be verified."
      } else if root.cwd.isEmpty || root.args.isEmpty {
        refusal = "Command or working directory could not be verified."
      } else if root.parent == 1 && !orphan && !LocalControllers.isMinecraftController(root) {
        refusal = "Launch ownership is unknown or managed. Stop it through its launcher."
      } else if let parent = all[root.parent], !launchBoundary(parent) {
        refusal = "A live supervisor owns this process. Stopping only its child could restart it."
      }
      var row = Workload(
        root: root, members: members, kind: type,
        name: name.isEmpty || name == "/" ? type.name.lowercased() : name, ports: memberPorts,
        provenance: provenance, orphan: orphan, refusal: refusal)
      row.usesMinecraftController = LocalControllers.isMinecraftController(root)
      if type.name == "Ollama" { row.name = "ollama" }
      if type.name == "Minecraft" {
        row.name = name.replacingOccurrences(
          of: "-[0-9]{10,}$", with: "", options: .regularExpression
        ).replacingOccurrences(of: "-", with: " ")
      }
      if let existing = result[root.identity], !existing.kind.background { continue }
      result[root.identity] = row
    }
    // Remove nested rows; the containing workload owns metrics and actions.
    let values = Array(result.values)
    return values.filter { w in
      !values.contains { $0.id != w.id && $0.members.contains { $0.identity == w.id } }
    }.sorted {
      ($0.ports.isEmpty ? 1 : 0, $0.name, $0.root.pid) < (
        $1.ports.isEmpty ? 1 : 0, $1.name, $1.root.pid
      )
    }
  }
  public static func validate(_ w: Workload, live: [Int32: Proc]) throws {
    if w.usesMinecraftController && !LocalControllers.isMinecraftController(w.root) {
      throw SafetyError("Audited Minecraft controller changed. Refusing to signal it.")
    }
    if let reason = w.refusal { throw SafetyError(reason) }
    let current = descendants(w.root.pid, live)
    guard Set(current.map(\.identity)) == Set(w.members.map(\.identity)),
      let root = live[w.root.pid], root.parent == w.root.parent,
      root.parentUnique == w.root.parentUnique
    else { throw SafetyError("Process tree changed. Refresh and inspect it again.") }
    if let parent = live[w.root.parent], w.root.parentUnique != 0,
      parent.identity.unique != w.root.parentUnique
    {
      throw SafetyError("Parent process identity changed.")
    }
    for p in current {
      guard !protected(p), let old = w.members.first(where: { $0.identity == p.identity }),
        old.parent == p.parent, old.parentUnique == p.parentUnique, old.path == p.path,
        old.args == p.args, old.cwd == p.cwd
      else { throw SafetyError("Process identity, ownership, or command changed.") }
      if let parent = live[p.parent], p.parentUnique != 0, parent.identity.unique != p.parentUnique
      {
        throw SafetyError("A process parent changed generation.")
      }
    }
  }
}
public struct SafetyError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
