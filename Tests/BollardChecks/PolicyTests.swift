import BollardCore
import CoreGraphics
import CryptoKit
import Foundation

func sha256Text(_ s: String) -> String {
  SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct PolicyTests {
  func p(
    _ id: Int32, _ parent: Int32, _ path: String, _ args: [String], cwd: String = "/tmp/project"
  ) -> Proc {
    Proc(pid: id, parent: parent, path: path, cwd: cwd, args: args)
  }
  func l(_ port: Int, _ pid: Int32, wildcard: Bool = false) -> Listener {
    Listener(port: port, address: wildcard ? "0.0.0.0" : "127.0.0.1", wildcard: wildcard, pid: pid)
  }
  func check(_ condition: Bool, _ message: String, line: Int = #line) {
    precondition(condition, "line \(line): \(message)")
  }

  func testSiblingAndShellBoundary() {
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let a = p(11, 10, "/opt/homebrew/bin/node", ["node", "/tmp/project/server.js"])
    let b = p(12, 10, "/opt/homebrew/bin/node", ["node", "/tmp/project/other.js"])
    let rows = Policy.workloads([10: shell, 11: a, 12: b], listeners: [l(3000, 11), l(3001, 12)])
    check(rows.count == 2, "two sibling servers")
    for row in rows {
      check(
        row.members.count == 1 && row.blocked == nil && row.cautions.isEmpty, "each stoppable alone"
      )
      check(row.section == .servers && row.provenance == "Terminal · zsh", "\(row.provenance)")
    }
  }
  func testProtectedProcessesAreNeverRoots() {
    let agent = p(20, 1, "/usr/local/bin/claude", ["claude"])
    let terminal = p(
      21, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"])
    let shell = p(22, 1, "/bin/zsh", ["-zsh"])
    let editor = p(
      23, 1, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", ["Electron"])
    let rows = Policy.workloads(
      [20: agent, 21: terminal, 22: shell, 23: editor],
      listeners: [l(1, 20), l(2, 21), l(3, 22), l(4, 23)])
    check(
      rows.count == 4 && rows.allSatisfy { $0.blocked != nil && $0.members.isEmpty },
      "all read only")
    check(rows.first { $0.root.pid == 23 }?.section == .apps, "editor listed under Apps")
    check(rows.first { $0.root.pid == 20 }?.section == .system, "agent listed under System")
    let versioned = p(
      24, 1, "/Users/me/.local/share/claude/versions/2.1.309", ["claude", "bg-spare"])
    let server = p(25, 24, "/usr/bin/python3", ["python3", "-m", "http.server"])
    let spawned = Policy.workloads(
      [24: versioned, 25: server], listeners: [l(8000, 25), l(8001, 24)])
    check(spawned.first { $0.root.pid == 24 }?.blocked != nil, "version-named claude is an agent")
    let child = spawned.first { $0.root.pid == 25 }!
    check(
      child.provenance == "Claude Code" && child.cautions.isEmpty,
      "\(child.provenance) \(child.cautions)")
    check(Policy.workloads([22: shell], listeners: []).isEmpty, "a silent shell is not a workload")
  }
  func testToolsAreVisibleButReadOnly() {
    for (path, args) in [
      ("/opt/homebrew/bin/node", ["node", "/x/playwright-mcp"]),
      ("/usr/bin/java", ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]),
      ("/usr/bin/python3", ["python3", "-m", "ipykernel_launcher"]),
    ] {
      let rows = Policy.workloads([20: p(20, 1, path, args)], listeners: [l(9999, 20)])
      check(rows.count == 1 && rows[0].section == .system && rows[0].blocked != nil, "\(args)")
      check(
        Policy.workloads([20: p(20, 1, path, args)], listeners: []).isEmpty,
        "silent tools stay hidden")
    }
  }
  func testApplicationsMergeHelpers() {
    let main = p(40, 1, "/Applications/1Password.app/Contents/MacOS/1Password", ["1Password"])
    let helper = p(
      41, 40,
      "/Applications/1Password.app/Contents/Frameworks/1Password Helper.app/Contents/MacOS/1Password Helper",
      ["1Password Helper"])
    let rows = Policy.workloads([40: main, 41: helper], listeners: [l(6263, 41), l(6264, 40)])
    check(rows.count == 1, "one row per application")
    let row = rows[0]
    check(
      row.root.pid == 40 && row.section == .apps && row.blocked == nil, "rooted at the main process"
    )
    check(
      row.ports == [6263, 6264] && row.members.count == 2 && row.name == "1Password",
      "\(row.ports) \(row.name)")
    check(row.restartReason != nil, "apps do not restart from Terminal")
  }
  func testFrameworkPythonIsNotAnApp() {
    let python = p(
      50, 10,
      "/opt/homebrew/Cellar/python@3.12/3.12.15_1/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
      ["Python", "-m", "archon.app", "serve"], cwd: "/Users/me/archon")
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let rows = Policy.workloads([10: shell, 50: python], listeners: [l(8848, 50)])
    check(
      rows.count == 1 && rows[0].section == .servers && rows[0].name == "archon",
      "\(rows.map(\.name))")
    check(rows[0].kind.name == "Python", rows[0].kind.name)
    let xcode = p(
      51, 10,
      "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
      ["python3", "stubborn.py"], cwd: "/tmp/fixture")
    let system = Policy.workloads([10: shell, 51: xcode], listeners: [l(8000, 51)]).first!
    check(
      system.section == .servers && system.blocked == nil && system.name == "fixture",
      "system python is not Xcode: \(system.blocked ?? "")")
    let chrome = p(
      52, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["Google Chrome"])
    let helper = p(
      53, 52,
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
      ["Google Chrome Helper"])
    let app = Policy.workloads([52: chrome, 53: helper], listeners: [l(9222, 53)])
    check(
      app.count == 1 && app[0].root.pid == 52 && app[0].section == .apps && app[0].ports == [9222],
      "browser helper merges into its app")
  }
  func testSystemAndForeignListeners() {
    let other = Proc(pid: 60, parent: 1, uid: 0, path: "", args: [])
    let daemon = p(61, 1, "/usr/libexec/rapportd", ["rapportd"])
    let center = p(
      62, 1, "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
      ["ControlCenter"])
    check(
      Policy.workloads([62: center], listeners: [l(7000, 62, wildcard: true)]).first?.section
        == .system, "system apps are System")
    let rows = Policy.workloads(
      [60: other, 61: daemon], listeners: [l(22, 60), l(49152, 61, wildcard: true)])
    check(
      rows.count == 2 && rows.allSatisfy { $0.section == .system && $0.blocked != nil },
      "system rows read only")
    check(rows.first { $0.root.pid == 61 }?.exposed == true, "wildcard listener flagged")
  }
  func testDetachedServerIsStoppable() {
    let s = p(21, 1, "/opt/homebrew/bin/node", ["node", "server.js"])
    let row = Policy.workloads([21: s], listeners: [l(3000, 21)]).first!
    check(!row.orphan && row.blocked == nil && row.cautions.isEmpty, "\(row.cautions)")
    check(row.provenance.hasPrefix("Detached"), row.provenance)
    check(row.restartReason == nil, row.restartReason ?? "")
  }
  func testLaunchdAndHomebrewCautions() {
    let s = p(21, 1, "/opt/homebrew/bin/node", ["node", "server.js"])
    let row = Policy.workloads(
      [21: s], listeners: [l(3000, 21)], labels: [21: "homebrew.mxcl.postgresql@17"]
    ).first!
    check(row.blocked == nil && row.brewService == "postgresql@17", row.brewService ?? "nil")
    check(row.cautions.first?.contains("Homebrew service postgresql@17") == true, "\(row.cautions)")
    check(row.restartReason != nil, "launchd services do not restart from Terminal")
    let agent = Policy.workloads(
      [21: s], listeners: [l(3000, 21)], labels: [21: "local.storefront"]
    ).first!
    check(
      agent.cautions.first?.contains("launchd as local.storefront") == true, "\(agent.cautions)")
    check(agent.provenance == "launchd · local.storefront", agent.provenance)
  }
  func testSupervisorIsCautionNotRefusal() {
    let supervisor = p(10, 1, "/bin/zsh", ["zsh", "-c", "while true; do node server.js; done"])
    let child = p(11, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let row = Policy.workloads([10: supervisor, 11: child], listeners: [l(3000, 11)]).first!
    check(row.blocked == nil && row.root.pid == 11, "child remains the root")
    check(row.cautions.first?.contains("may restart it") == true, "\(row.cautions)")
    let plain = p(10, 1, "/bin/zsh", ["zsh", "-c", "node server.js & node other.js & wait"])
    let quiet = Policy.workloads([10: plain, 11: child], listeners: [l(3000, 11)]).first!
    check(quiet.cautions.isEmpty, "\(quiet.cautions)")
  }
  func testWrapperPromotion() {
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let npm = p(
      11, 10, "/opt/homebrew/bin/node",
      ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"])
    let wrapper = p(12, 11, "/bin/sh", ["sh", "-c", "next dev"])
    let server = p(
      13, 12, "/opt/homebrew/bin/node",
      ["node", "/tmp/project/node_modules/next/dist/bin/next", "dev"])
    let row = Policy.workloads(
      [10: shell, 11: npm, 12: wrapper, 13: server], listeners: [l(3000, 13)]
    ).first!
    check(
      row.root.pid == 11 && row.members.count == 3 && row.blocked == nil && row.cautions.isEmpty,
      "npm owns the tree")
    check(row.kind.name == "Next.js", row.kind.name)
    let tsx = p(
      20, 10, "/opt/homebrew/bin/node", ["node", "node_modules/.bin/tsx", "watch", "src/server.ts"])
    let child = p(
      21, 20, "/opt/homebrew/bin/node",
      ["node", "--require", "/x/node_modules/tsx/dist/preflight.cjs", "src/server.ts"])
    let promoted = Policy.workloads([10: shell, 20: tsx, 21: child], listeners: [l(4000, 21)])
      .first!
    check(promoted.root.pid == 20 && promoted.members.count == 2, "tsx promoted")
  }
  func testKillSetExcludesProtectedDescendants() {
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let node = p(21, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let agent = p(22, 21, "/usr/local/bin/codex", ["codex"])
    let grandchild = p(23, 22, "/opt/homebrew/bin/node", ["node", "mcp.js"])
    let row = Policy.workloads(
      [10: shell, 21: node, 22: agent, 23: grandchild], listeners: [l(3000, 21)]
    ).first!
    check(row.blocked == nil && row.members.map(\.pid) == [21], "\(row.members.map(\.pid))")
    check(row.excluded.map(\.pid) == [22], "agent excluded with its subtree")
    check(row.cautions.contains { $0.hasPrefix("Leaves running: codex (22)") }, "\(row.cautions)")
  }
  func testMinecraftIsNotWeb() {
    let s = p(21, 10, "/usr/bin/java", ["java", "-jar", "server.jar", "nogui"])
    let row = Policy.workloads([21: s], listeners: [l(25565, 21)]).first!
    check(row.kind.name == "Minecraft" && !row.kind.web, row.kind.name)
    check(row.cautions.contains { $0.contains("Force Quit skips saving") }, "\(row.cautions)")
  }
  func testBackgroundAndAI() {
    let watcher = p(31, 10, "/opt/homebrew/bin/node", ["node", "tsc", "--watch"])
    let rows = Policy.workloads([31: watcher], listeners: [])
    check(rows.first?.kind.name == "Watcher" && rows.first?.section == .background, "watcher")
    let ollama = p(
      32, 1, "/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"])
    check(
      Policy.workloads([32: ollama], listeners: [l(11434, 32)]).first?.section == .apps,
      "bundled ollama is an app")
    let client = p(33, 1, "/usr/bin/java", ["java", "org.prismlauncher.EntryPoint"])
    check(
      Policy.workloads([33: client], listeners: [l(7881, 33)]).first?.blocked != nil,
      "game client read only")
    let notebook = p(34, 10, "/opt/homebrew/bin/python3", ["python3", "-m", "jupyter", "lab"])
    check(
      Policy.workloads([34: notebook], listeners: [l(8888, 34)]).first?.kind.name == "Jupyter",
      "jupyter")
    let llama = p(35, 1, "/opt/homebrew/bin/llama-server", ["llama-server", "-m", "x.gguf"])
    check(
      Policy.workloads([35: llama], listeners: [l(9931, 35)]).first?.kind.name == "AI service",
      "llama")
    let unknown = p(36, 10, "/opt/homebrew/bin/workerd", ["workerd", "serve"])
    check(
      Policy.workloads([36: unknown], listeners: [l(8787, 36)]).first?.kind.name == "Wrangler",
      "any listener is shown")
  }
  func testValidateTracksLiveTree() throws {
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let root = p(20, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let child = Proc(
      pid: 21, parent: 20, parentUnique: 20, path: "/opt/homebrew/bin/node",
      args: ["node", "worker.js"])
    let all: [Int32: Proc] = [10: shell, 20: root, 21: child]
    let w = Policy.workloads(all, listeners: [l(3000, 20)]).first!
    check(try Policy.validate(w, live: all).map(\.pid) == [20, 21], "kill set unchanged")
    var live = all
    live[21] = nil
    check(try Policy.validate(w, live: live).map(\.pid) == [20], "exited member is fine")
    live = all
    live[22] = p(22, 20, "/opt/homebrew/bin/node", ["node", "late.js"])
    check(
      try Policy.validate(w, live: live).map(\.pid) == [20, 21, 22],
      "new descendant joins the kill set")
    live = all
    live[23] = p(23, 20, "/usr/local/bin/claude", ["claude"])
    check(
      try Policy.validate(w, live: live).map(\.pid) == [20, 21], "new protected child is skipped")
    live = all
    live[20] = Proc(
      pid: 20, parent: 10, start: 2, unique: 22, version: 2, path: root.path, args: root.args)
    do {
      try Policy.validate(w, live: live)
      fatalError("PID reuse accepted")
    } catch {}
    live = all
    live[21] = Proc(pid: 21, parent: 20, parentUnique: 20, path: "/bin/zsh", args: ["-zsh"])
    do {
      try Policy.validate(w, live: live)
      fatalError("Changed member command accepted")
    } catch {}
  }
  func testLaunchOwnershipTransitions() throws {
    var cache = LaunchOwnershipCache()
    var calls = 0
    let original = p(10, 1, "/usr/bin/node", ["node", "server.js"])
    let first = cache.update(roots: [original], processes: [10: original]) {
      calls += 1
      return [10: "first"]
    }
    check(first[10] == "first" && calls == 1, "fetched once")
    _ = cache.update(roots: [original], processes: [10: original]) {
      fatalError("Unchanged generation fetched again")
    }
    let reused = Proc(
      pid: 10, parent: 1, start: 2, unique: 11, path: original.path, args: original.args)
    check(cache.current(in: [10: reused]).isEmpty, "reused pid has no label")
    let second = cache.update(roots: [reused], processes: [10: reused]) {
      calls += 1
      return [10: "second"]
    }
    check(second[10] == "second" && calls == 2, "refetched for new generation")
    let fresh = p(12, 1, "/usr/bin/node", ["node", "server.js"])
    do {
      _ = try cache.update(roots: [fresh], processes: [12: fresh]) {
        calls += 1
        throw SafetyError("lookup failed")
      }
      fatalError("Failure swallowed")
    } catch {}
    let retry = cache.update(roots: [fresh], processes: [12: fresh]) {
      calls += 1
      return [12: "retry"]
    }
    check(retry[12] == "retry" && calls == 4, "retried after failure")
  }
  func testTextHelpers() {
    check(
      shellQuote("abc") == "abc" && shellQuote("a b") == "'a b'"
        && shellQuote("it's") == "'it'\\''s'", "quoting")
    check(
      uptimeText(45) == "45s" && uptimeText(3700) == "1h 1m" && uptimeText(200_000) == "2d 7h",
      "uptime")
    check(memoryText(2_500_000_000) == "2.5 GB" && memoryText(12_000_000) == "12 MB", "memory")
    check("hello world".has("o w") && !"hello".has("") && !"abc".has("abd"), "byte search")
  }
  func testGitBranchAndWorktree() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bollard-git-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git/worktrees/feature"), withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(
      to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
    check(
      Git.read(repo.appendingPathComponent("src/deep").path) == "main", "branch from a subdirectory"
    )
    let worktree = root.appendingPathComponent("feature-wt")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/feature\n".write(
      to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "ref: refs/heads/feature/login\n".write(
      to: repo.appendingPathComponent(".git/worktrees/feature/HEAD"), atomically: true,
      encoding: .utf8)
    check(Git.read(worktree.path) == "feature/login · feature", Git.read(worktree.path) ?? "nil")
    try "0123456789abcdef0123456789abcdef01234567\n".write(
      to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    check(Git.read(repo.path) == "01234567", "detached HEAD shows a short sha")
    check(Git.read(root.path) == nil, "no checkout, no branch")
  }
  func testDeclaredControllers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bollard-ctl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = "print('stop')\n"
    try script.write(
      to: dir.appendingPathComponent("control.py"), atomically: true, encoding: .utf8)
    let sha = "a0b1"  // wrong on purpose first
    let config = dir.appendingPathComponent("controllers.json")
    func write(_ hash: String) throws {
      try """
      {"controllers": [{"directory": "\(dir.path)", "script": "control.py", "sha256": "\(hash)", "label": "Test controller", "timeout": 5}]}
      """.write(to: config, atomically: true, encoding: .utf8)
    }
    try write(sha)
    Controllers.file = config
    let proc = Proc(
      pid: 70, parent: 10, path: "/opt/homebrew/bin/python3", cwd: dir.path,
      args: ["python3", dir.appendingPathComponent("control.py").path, "run"])
    check(Controllers.match(proc) == nil, "wrong fingerprint is not trusted")
    let real = sha256Text(script)
    Thread.sleep(forTimeInterval: 1.1)  // config mtime resolution
    try write(real)
    let matched = Controllers.match(proc)
    check(
      matched?.label == "Test controller" && matched?.stopTimeout == 5,
      "matching fingerprint is trusted")
    let shell = p(10, 1, "/bin/zsh", ["-zsh"])
    let server = Proc(
      pid: 71, parent: 70, path: "/usr/bin/java", cwd: dir.path,
      args: ["java", "-jar", "server.jar", "nogui"])
    let rows = Policy.workloads([10: shell, 70: proc, 71: server], listeners: [l(25565, 71)])
    check(
      rows.count == 1 && rows[0].root.pid == 70 && rows[0].controller != nil,
      "server promotes to its controller")
    check(
      rows[0].provenance == "Test controller" && rows[0].cautions.isEmpty,
      "\(rows[0].provenance) \(rows[0].cautions)")
    try "print('changed')\n".write(
      to: dir.appendingPathComponent("control.py"), atomically: true, encoding: .utf8)
    var threw = false
    do { try Policy.validate(rows[0], live: [10: shell, 70: proc, 71: server]) } catch {
      threw = true
    }
    check(threw, "an edited controller script is refused")
  }
  func testPanelWithinEveryScreen() {
    for screen in [
      CGRect(x: 0, y: 0, width: 1512, height: 945),
      CGRect(x: -1920, y: 100, width: 1920, height: 1080),
      CGRect(x: 0, y: 0, width: 800, height: 500),
    ] {
      for x in [screen.minX, screen.midX, screen.maxX] {
        let frame = PanelPlacement.frame(
          anchor: CGRect(x: x, y: screen.maxY, width: 30, height: 25), screen: screen,
          desiredHeight: 1500)
        check(screen.contains(frame), "Panel would leave screen")
      }
    }
  }
}

@main struct Checks {
  static func main() throws {
    let t = PolicyTests()
    t.testSiblingAndShellBoundary()
    t.testProtectedProcessesAreNeverRoots()
    t.testToolsAreVisibleButReadOnly()
    t.testApplicationsMergeHelpers()
    t.testFrameworkPythonIsNotAnApp()
    t.testSystemAndForeignListeners()
    t.testDetachedServerIsStoppable()
    t.testLaunchdAndHomebrewCautions()
    t.testSupervisorIsCautionNotRefusal()
    t.testWrapperPromotion()
    t.testKillSetExcludesProtectedDescendants()
    t.testMinecraftIsNotWeb()
    t.testBackgroundAndAI()
    try t.testValidateTracksLiveTree()
    try t.testLaunchOwnershipTransitions()
    t.testTextHelpers()
    t.testPanelWithinEveryScreen()
    try t.testGitBranchAndWorktree()
    try t.testDeclaredControllers()
    print("19 policy checks passed")
    if CommandLine.arguments.contains("--socket-parity") {
      try socketParityChecks()
    } else if !CommandLine.arguments.contains("--policy-only") {
      try liveChecks()
      try serviceChecks()
    }
  }
}
