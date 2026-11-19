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
  func l(_ port: Int, _ pid: Int32, wildcard: Bool = false, _ transport: Transport = .tcp)
    -> Listener
  {
    Listener(
      port: port, address: wildcard ? "0.0.0.0" : "127.0.0.1", wildcard: wildcard, pid: pid,
      transport: transport, socket: UInt64(port))
  }
  let shell = Proc(pid: 10, parent: 1, path: "/bin/zsh", args: ["-zsh"])
  let python = "/opt/homebrew/bin/python3"
  let node = "/opt/homebrew/bin/node"
  func row(_ rows: [Workload], _ pid: Int32) -> Workload? { rows.first { $0.root.pid == pid } }
  func check(_ condition: Bool, _ message: String, line: Int = #line) {
    precondition(condition, "line \(line): \(message)")
  }

  /// The cases the allow-list missed: nothing here is a recognised framework, and all of it is
  /// something the user left running.
  func testEveryLongLivedTreeIsAWorkload() {
    let all: [Int32: Proc] = [
      10: shell,
      11: p(11, 10, python, ["python3", "-c", "import time; time.sleep(9)"]),
      12: p(12, 10, node, ["node", "-e", "setInterval(()=>{},1000)"]),
      13: p(13, 10, "/bin/bash", ["bash", "loop.sh"]),
      14: p(14, 10, "/tmp/project/labdaemon", ["./labdaemon"]),
      15: p(15, 10, python, ["python3", "worker.py"]),
      16: p(16, 10, python, ["python3", "-m", "http.server", "8000"]),
      17: p(17, 10, python, ["python3", "udp.py"]),
      18: p(18, 10, python, ["python3", "unix.py"]),
    ]
    let unix = Listener(
      port: 0, address: "", pid: 18, transport: .unix, path: "/tmp/x.sock", socket: 9)
    let rows = Policy.workloads(all, listeners: [l(8000, 16), l(5353, 17, .udp), unix])
    check(rows.count == 8, "eight workloads, found \(rows.map(\.detail))")
    check(rows.allSatisfy { $0.blocked == nil && $0.cautions.isEmpty }, "all stoppable")
    check(
      Set(rows.filter { $0.section == .servers }.map(\.root.pid)) == [16, 17],
      "TCP and UDP ports make a server")
    check(row(rows, 18)?.endpoints == ["/tmp/x.sock"], "a Unix socket is shown, not a port")
    check(row(rows, 16)?.kind == Kind(name: "Python HTTP", icon: "globe", web: true), "http.server")
    check(row(rows, 16)?.url?.absoluteString == "http://localhost:8000", "web servers have a URL")
    check(row(rows, 17)?.url == nil && row(rows, 17)?.endpoints == ["127.0.0.1:5353/udp"], "UDP")
    check(
      [11, 12, 13, 14, 15].map { row(rows, $0)?.detail ?? "" } == [
        "python3 -c", "node -e", "loop.sh", "labdaemon", "worker.py",
      ], "each row says what it runs: \(rows.map(\.detail))")
    check(row(rows, 14)?.kind.name == "labdaemon", "an unknown binary goes by its own name")
    check(rows.allSatisfy { $0.provenance == "Terminal · zsh" }, "launched from the shell")
  }
  func testOneShotCommandsSettleFirst() {
    let all: [Int32: Proc] = [
      10: shell, 11: p(11, 10, "/usr/bin/grep", ["grep", "-r", "x"]),
      12: p(12, 10, node, ["node", "server.js"]),
    ]
    let young = Policy.workloads(all, listeners: [l(3000, 12)], now: 2)
    check(young.map(\.root.pid) == [12], "a quiet command is not listed in its first seconds")
    check(Policy.workloads(all, listeners: [l(3000, 12)], now: 9).count == 2, "then it is")
  }
  func testProgramsAreNamedNotGuessed() {
    func program(_ path: String, _ args: [String]) -> Program { p(1, 1, path, args).program }
    func kind(_ path: String, _ args: [String], cwd: String = "/tmp/project") -> String {
      let proc = p(99, 10, path, args, cwd: cwd)
      return (Kinds.known(proc.program, proc) ?? Kinds.fallback(proc.program, proc)).name
    }
    // The old substring matcher called all of these Vite, Astro, Remix, Minecraft or a tool.
    check(
      kind(node, ["node", "/Users/me/invite/astro-notes/remix-paper-/mcp/server.js"]) == "Node.js",
      "paths never classify")
    check(kind(python, ["python3", "-m", "uvicorn", "app:app"]) == "Uvicorn", "module")
    check(
      kind(python, ["python3", "/x/.venv/bin/uvicorn", "app:app"]) == "Uvicorn", "console script")
    check(kind(python, ["python3", "manage.py", "runserver"]) == "Django", "manage.py runserver")
    check(kind(python, ["python3", "manage.py", "migrate"]) == "Python", "manage.py alone is not")
    let next = program(node, ["node", "/x/node_modules/next/dist/bin/next", "dev"])
    check(next.target == "next" && next.summary == "next dev" && !next.wrapper, "\(next)")
    check(kind(node, ["node", "/x/node_modules/.bin/vite"]) == "Vite", ".bin shim")
    check(kind(node, ["node", "/x/node_modules/@playwright/mcp/cli.js"]) == "MCP server", "scoped")
    check(kind(node, ["npm exec chrome-devtools-mcp@1.10.1 --isolated"]) == "MCP server", "title")
    check(kind(node, ["next-server (v15.1.0)"]) == "Next.js", "rewritten process title")
    check(
      kind("/opt/homebrew/bin/uv", ["uv", "run", "uvicorn", "main:app"]) == "Uvicorn", "runner")
    check(kind("/Users/me/.local/bin/bollard", ["bollard", "--mcp"]) == "MCP server", "--mcp flag")
    check(
      kind("/usr/bin/ssh", ["ssh", "-N", "-L", "8080:localhost:80", "host"]) == "SSH tunnel",
      "ssh -L")
    check(
      kind("/usr/bin/java", ["java", "-Xmx4G", "-jar", "server.jar", "nogui"]) == "Minecraft", "jar"
    )
    check(
      kind("/opt/homebrew/bin/postgres", ["postgres", "-D", "/data"]) == "PostgreSQL", "database")
    let npm = program(
      node, ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"])
    check(npm.wrapper && npm.summary == "npm run dev", "\(npm)")
    check(
      program("/bin/zsh", ["-zsh"]).repl && !program("/bin/bash", ["bash", "x.sh"]).repl, "shells")
    check(program("/bin/zsh", ["zsh", "-c", "sleep 9"]).wrapper, "sh -c is a wrapper")
    check(program(python, ["python3"]).repl && program(node, ["node"]).repl, "bare interpreters")
    check(
      Program.shellSummary("source /x/snap.sh && eval 'npm run dev' \\< /dev/null && pwd")
        == "npm run dev",
      "agent shell preamble is stripped")
  }
  func testWrappersLeadToTheWork() {
    let all: [Int32: Proc] = [
      10: shell,
      20: p(
        20, 10, node, ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"]),
      21: p(21, 20, "/bin/sh", ["sh", "-c", "next dev"]),
      22: p(22, 21, node, ["node", "/tmp/project/node_modules/next/dist/bin/next", "dev"]),
      30: p(30, 10, "/bin/zsh", ["zsh", "-c", "node a.js & node b.js & wait"]),
      31: p(31, 30, node, ["node", "a.js"]), 32: p(32, 30, node, ["node", "b.js"]),
    ]
    let rows = Policy.workloads(all, listeners: [l(3000, 22), l(3001, 31), l(3002, 32)])
    check(rows.count == 2, "one row per tree: \(rows.map(\.root.pid))")
    let dev = row(rows, 20)!
    check(
      dev.lead.pid == 22 && dev.kind.name == "Next.js" && dev.detail == "next dev"
        && dev.members.map(\.pid) == [20, 21, 22], "npm run dev is the Next.js server it starts")
    let fan = row(rows, 30)!
    check(fan.ports == [3001, 3002] && fan.members.count == 3, "a fan-out is one workload")
    check(fan.detail == "node a.js & node b.js & wait" && fan.kind.web, "\(fan.detail)")
  }
  func testAgentsAreRowsWithTheirHelpers() {
    let all: [Int32: Proc] = [
      10: shell, 40: p(40, 10, "/Users/me/.local/bin/claude", ["claude"]),
      41: p(41, 40, node, ["node", "/x/node_modules/@playwright/mcp/cli.js"]),
      42: p(42, 40, "/bin/zsh", ["zsh", "-c", "python3 -m http.server"]),
      43: p(43, 42, python, ["python3", "-m", "http.server"]),
      44: p(44, 40, "/Users/me/.local/share/claude/versions/2.1.309", ["claude", "bg-spare"]),
      45: p(45, 40, "/bin/zsh", ["zsh", "-c", "until curl -sf localhost:8000; do sleep 5; done"]),
      46: p(46, 45, "/bin/sleep", ["sleep", "5"]),
    ]
    let rows = Policy.workloads(all, listeners: [l(8000, 43)])
    check(rows.count == 3, "\(rows.map(\.root.pid))")
    let waiting = row(rows, 45)!
    check(
      waiting.section == .commands
        && waiting.detail == "until curl -sf localhost:8000; do sleep 5; done"
        && waiting.kind.name == "Shell script",
      "a shell the agent is waiting in is one of its commands, described by its loop: \(waiting.detail)"
    )
    let agent = row(rows, 40)!
    check(
      agent.section == .agents && agent.kind.name == "Claude Code" && agent.blocked == nil
        && agent.members.map(\.pid) == [40, 41, 44] && agent.detail == "1 helper",
      "the agent owns its helper and its own subprocess: \(agent.members.map(\.pid))")
    let server = row(rows, 42)!
    check(
      server.origin == "Claude Code" && server.members.map(\.pid) == [42, 43]
        && server.section == .servers, "what the agent ran through its shell is its own row")
    check(Policy.killSet(40, all).members.map(\.pid) == [40, 41, 44], "ending the agent spares it")
    check(
      Policy.agent(p(1, 1, "/Applications/Claude.app/Contents/MacOS/Claude", ["Claude"])) == nil,
      "the desktop application is not the agent")
    check(
      Policy.agent(
        p(
          1, 1,
          "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude",
          ["claude"])) == "Claude Code", "the agent it embeds is")
    check(
      Policy.agent(p(1, 1, python, ["python3", "claude.py"])) == nil,
      "a script named like one is not")
    check(
      Policy.agent(p(1, 1, python, ["python3", "-m", "aider"])) == "Aider", "a hosted agent is")
  }
  func testApplicationsAndTheirHelpers() {
    let app = "/Applications/Foo.app/Contents"
    let all: [Int32: Proc] = [
      50: p(50, 1, "\(app)/MacOS/Foo", ["Foo"]),
      51: p(51, 50, "\(app)/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper", ["Foo Helper"]),
      52: p(52, 50, python, ["python3", "language_server.py"]),
      53: p(53, 50, node, ["node", "preview.js"]),
      54: p(
        54, 1, "\(app)/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler",
        ["chrome_crashpad_handler"]),
      55: p(
        55, 1,
        "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
        ["Python", "/Users/me/repo/job.py"], cwd: "/"),
      56: p(
        56, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"]),
      57: p(
        57, 1,
        "/Applications/Xcode.app/Contents/Developer/Toolchains/X.xctoolchain/usr/lib/sourcekitd.framework/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService",
        ["SourceKitService"]),
      58: p(58, 1, "/Applications/Xcode.app/Contents/MacOS/Xcode", ["Xcode"]),
      59: p(59, 58, "/Users/me/api/.build/debug/App", ["App", "serve"]),
    ]
    let rows = Policy.workloads(
      all, listeners: [l(9000, 51), l(9100, 53), l(9200, 56), l(8080, 59)])
    check(Set(rows.map(\.root.pid)) == [50, 55, 56, 59], "\(rows.map(\.root.pid))")
    let foo = row(rows, 50)!
    check(
      foo.section == .apps && foo.name == "Foo" && foo.ports == [9000, 9100] && foo.blocked == nil
        && foo.members.map(\.pid) == [50, 51, 52, 53], "helpers merge into the application")
    check(
      row(rows, 59)?.section == .servers && row(rows, 59)?.origin == "Xcode",
      "what an editor runs is a server of its own, since the editor is never quit")
    let job = row(rows, 55)!
    check(
      job.section == .background && job.name == "repo" && job.detail == "job.py",
      "a runtime shipped inside a bundle runs the user's code: \(job.name) \(job.detail)")
    check(row(rows, 56)?.blocked == "Bollard never quits a macOS system process.", "Terminal")
  }
  func testOpenApplicationsAreListed() {
    let all: [Int32: Proc] = [
      60: p(
        60, 1,
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
        ["Safari"]),
      61: p(61, 1, "/Applications/Notes.app/Contents/MacOS/Notes", ["Notes"]),
      62: p(
        62, 61,
        "/Applications/Notes.app/Contents/Frameworks/Notes Helper.app/Contents/MacOS/Notes Helper",
        ["Notes Helper"]),
      63: p(
        63, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"]),
      64: p(64, 1, "/Applications/Menulet.app/Contents/MacOS/Menulet", ["Menulet"]),
    ]
    check(Policy.workloads(all, listeners: []).isEmpty, "without the open set, only listeners")
    let rows = Policy.workloads(all, listeners: [], apps: [60, 61, 63])
    check(
      rows.map(\.name) == ["Notes", "Safari", "Terminal"]
        && rows.allSatisfy { $0.section == .apps },
      "every open application, and not the menu bar extra nobody opened: \(rows.map(\.name))")
    check(row(rows, 61)?.members.map(\.pid) == [61, 62], "with its helpers")
    check(row(rows, 60)?.blocked == nil, "Apple's applications can be asked to quit")
    check(
      row(rows, 63)?.blocked == "Bollard never quits a terminal or editor.", "a terminal cannot")
    check(Policy.protection(all[60]!) != nil, "and none of them is ever signalled as a process")
  }
  func testTerminalSessionsAreNotWorkloads() {
    func foreground(_ id: Int32, _ path: String, _ args: [String]) -> Proc {
      var proc = p(id, 10, path, args)
      proc.foreground = true
      return proc
    }
    let all: [Int32: Proc] = [
      10: shell, 60: foreground(60, "/usr/bin/vim", ["vim", "notes.md"]),
      61: foreground(61, python, ["python3"]),
      62: foreground(62, python, ["python3", "train.py"]),
      63: p(63, 1, "/opt/homebrew/bin/tmux", ["tmux", "new"]),
      64: p(64, 63, "/bin/zsh", ["-zsh"]), 65: p(65, 64, node, ["node", "bot.js"]),
      66: foreground(66, "/usr/bin/ssh", ["ssh", "host"]),
      67: p(67, 10, "/usr/bin/vim", ["vim", "-es", "batch.vim"]),
    ]
    let rows = Policy.workloads(all, listeners: [])
    check(
      rows.map(\.root.pid) == [62, 65, 67],
      "editors, prompts and remote sessions in a tab are not workloads; scripts are: \(rows.map(\.root.pid))"
    )
    check(Policy.protection(all[60]!) == "an interactive terminal program", "vim")
    check(Policy.protection(all[63]!) == "a login or session process", "tmux")
    check(Policy.protection(all[66]!) == "a remote session", "ssh")
    check(Policy.protection(shell) == "an interactive shell", "shell")
    check(Policy.protection(p(1, 0, "/sbin/launchd", ["launchd"])) == "launchd", "launchd")
    let tree: [Int32: Proc] = [
      10: shell, 70: p(70, 10, "/bin/bash", ["bash", "dev.sh"]),
      71: p(71, 70, "/bin/zsh", ["-zsh"]),
      72: p(72, 71, node, ["node", "x.js"]), 73: p(73, 70, node, ["node", "y.js"]),
    ]
    let set = Policy.killSet(70, tree)
    check(
      set.members.map(\.pid) == [70, 73] && set.excluded.map(\.pid) == [71],
      "an interactive shell inside a tree, and what runs under it, is left alone")
  }
  func testLaunchdJobs() {
    let home = NSHomeDirectory()
    var all: [Int32: Proc] = [
      80: p(
        80, 1, "/opt/homebrew/opt/postgresql@17/bin/postgres", ["postgres", "-D", "/data"],
        cwd: "/data"),
      81: p(81, 1, "/usr/bin/ssh-agent", ["ssh-agent", "-l"], cwd: "/"),
      82: p(82, 1, "\(home)/Library/Vendor/updater", ["updater"], cwd: "/"),
      83: p(83, 1, python, ["python3", "/Users/me/tools/relay.py"], cwd: "/"),
      84: p(84, 1, "/opt/bin/thing", ["thing"], cwd: "/"),
    ]
    let xcode = "/Applications/Xcode.app/Contents/Developer"
    all[85] = p(85, 1, "\(xcode)/usr/bin/ibtoold", ["ibtoold"], cwd: "/")
    all[86] = p(
      86, 1, "\(xcode)/usr/bin/python3", ["python3", "/Users/me/tools/sync.py"], cwd: "/")
    let labels: [Int32: String] = [
      80: "homebrew.mxcl.postgresql@17", 81: "com.openssh.ssh-agent", 83: "dev.me.relay",
      84: "dev.me.thing",
    ]
    let rows = Policy.workloads(all, listeners: [l(5432, 80)], labels: labels)
    check(
      rows.map(\.root.pid) == [80, 84, 83, 86],
      "Apple's agents, vendor helpers and toolchain daemons are hidden: \(rows.map(\.root.pid))")
    let brew = row(rows, 80)!
    check(
      brew.kind.name == "PostgreSQL" && brew.brewService == "postgresql@17"
        && brew.origin == "launchd"
        && brew.cautions.first?.contains("Homebrew service") == true, "\(brew.cautions)")
    check(
      row(rows, 83)?.name == "tools" && row(rows, 83)?.detail == "relay.py", "named by its script")
    check(row(rows, 84)?.name == "dev.me.thing", "or by its launchd label when it has no place")
  }
  func testSocketOwnersAndOrigins() {
    var orphan = p(92, 1, node, ["node", "server.js"])
    orphan.responsible = 40
    let all: [Int32: Proc] = [
      10: shell, 40: p(40, 10, "/Users/me/.local/bin/claude", ["claude"]),
      90: p(90, 10, "/opt/homebrew/bin/gunicorn", ["gunicorn", "app"]),
      91: p(91, 90, "/opt/homebrew/bin/gunicorn", ["gunicorn", "app"]), 92: orphan,
    ]
    let held = [l(8000, 91), l(8000, 90), l(3000, 92)]
    let owned = Policy.owners(held, in: all)
    check(
      owned.map(\.pid) == [92, 90], "an inherited socket belongs to the process that opened it")
    let rows = Policy.workloads(all, listeners: owned)
    check(
      row(rows, 92)?.origin == "Claude Code",
      "a server that outlived its shell still knows who started it")
    check(row(rows, 90)?.kind.name == "Gunicorn" && row(rows, 90)?.members.count == 2, "prefork")
    check(
      Listener(port: 80, address: "::1", pid: 1).text == "[::1]:80"
        && Listener(port: 80, address: "0.0.0.0", wildcard: true, pid: 1).text == "*:80",
      "endpoints")
  }
  func testProjectNames() {
    let api = p(95, 10, node, ["node", "server.js"], cwd: "/Users/me/shop/packages/api")
    let rows = Policy.workloads(
      [10: shell, 95: api], listeners: [l(3000, 95)],
      checkout: { $0.hasPrefix("/Users/me/shop") ? Checkout(name: "shop", branch: "main") : nil })
    check(rows[0].name == "shop" && rows[0].branch == "main", "named for its repository")
  }
  func testValidateTracksLiveTree() throws {
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
  func testTextHelpers() {
    check(
      shellQuote("abc") == "abc" && shellQuote("a b") == "'a b'"
        && shellQuote("it's") == "'it'\\''s'", "quoting")
    check(
      uptimeText(45) == "45s" && uptimeText(3700) == "1h 1m" && uptimeText(200_000) == "2d 7h",
      "uptime")
    check(memoryText(2_500_000_000) == "2.5 GB" && memoryText(12_000_000) == "12 MB", "memory")
  }
  func testGitCheckouts() throws {
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
      Git.read(repo.appendingPathComponent("src/deep").path)
        == Checkout(name: "repo", branch: "main"),
      "repository and branch from a subdirectory")
    let worktree = root.appendingPathComponent("feature-wt")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/feature\n".write(
      to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "ref: refs/heads/feature/login\n".write(
      to: repo.appendingPathComponent(".git/worktrees/feature/HEAD"), atomically: true,
      encoding: .utf8)
    check(
      Git.read(worktree.path) == Checkout(name: "repo", branch: "feature/login"),
      "a linked worktree goes by its repository's name")
    try "0123456789abcdef0123456789abcdef01234567\n".write(
      to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    check(Git.read(repo.path)?.branch == "01234567", "detached HEAD shows a short sha")
    check(Git.read(root.path) == nil, "no checkout")
  }
}

@main struct Checks {
  static func main() throws {
    let t = PolicyTests()
    t.testEveryLongLivedTreeIsAWorkload()
    t.testOneShotCommandsSettleFirst()
    t.testProgramsAreNamedNotGuessed()
    t.testWrappersLeadToTheWork()
    t.testAgentsAreRowsWithTheirHelpers()
    t.testApplicationsAndTheirHelpers()
    t.testOpenApplicationsAreListed()
    t.testTerminalSessionsAreNotWorkloads()
    t.testLaunchdJobs()
    t.testSocketOwnersAndOrigins()
    t.testProjectNames()
    try t.testValidateTracksLiveTree()
    try t.testLaunchOwnershipTransitions()
    t.testTextHelpers()
    t.testPanelWithinEveryScreen()
    try t.testGitCheckouts()
    try t.testDeclaredControllers()
    portChecks()
    try binaryChecks()
    print("17 policy checks passed")
    if !CommandLine.arguments.contains("--policy-only") {
      try ownListenerChecks()
      try socketParityChecks()
      try liveChecks()
      try serviceChecks()
    }
  }
}
