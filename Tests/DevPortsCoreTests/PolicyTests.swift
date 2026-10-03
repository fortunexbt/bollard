import CoreGraphics
import DevPortsCore
import Foundation

struct PolicyTests {
  func p(_ id: Int32, _ parent: Int32, _ path: String, _ args: [String]) -> Proc {
    Proc(pid: id, parent: parent, path: path, args: args)
  }
  func testSiblingAndShellBoundary() {
    let shell = p(10, 1, "/bin/zsh", ["zsh"])
    let a = p(11, 10, "/opt/homebrew/bin/node", ["node", "/tmp/project/server.js"])
    let b = p(12, 10, "/opt/homebrew/bin/node", ["node", "/tmp/project/other.js"])
    let rows = Policy.workloads([10: shell, 11: a, 12: b], ports: [11: [3000], 12: [3001]])
    precondition(rows.count == 2)
    precondition(rows.first { $0.root.pid == 11 }?.members.map(\.pid) == [11])
  }
  func testInfrastructureAndGradleAreHidden() {
    for (path, args) in [
      ("/opt/homebrew/bin/node", ["node", "/x/playwright-mcp"]),
      ("/usr/bin/java", ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]),
      ("/usr/bin/python3", ["python3", "-m", "ipykernel_launcher"]),
      ("/Applications/ChatGPT.app/Contents/node", ["node", "./server.mjs"]),
    ] {
      let proc = p(20, 1, path, args)
      precondition(Policy.workloads([20: proc], ports: [20: [9999]]).isEmpty)
    }
  }
  func testMinecraftIsNotWeb() {
    let s = p(21, 10, "/usr/bin/java", ["java", "-jar", "server.jar", "nogui"])
    let row = Policy.workloads([21: s], ports: [21: [25565]]).first
    precondition(row?.kind.name == "Minecraft")
    precondition(row?.kind.web == false)
  }
  func testProtectedDescendantRefuses() {
    let node = p(21, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let agent = p(22, 21, "/usr/local/bin/codex", ["codex"])
    precondition(
      Policy.workloads([21: node, 22: agent], ports: [21: [3000]]).first?.refusal != nil)
  }
  func testDetachedIsNotAutomaticallyOrphan() {
    let s = p(21, 1, "/opt/homebrew/bin/node", ["node", "server.js"])
    let row = Policy.workloads([21: s], ports: [21: [3000]]).first!
    precondition(!row.orphan)
    precondition(row.refusal != nil)
  }
  func testPIDReuseRejected() throws {
    let a = p(21, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let w = Policy.workloads([10: p(10, 1, "/bin/zsh", ["zsh"]), 21: a], ports: [21: [3000]]).first!
    let changed = Proc(
      pid: 21, parent: 10, start: 2, unique: 22, version: 2, path: a.path, args: a.args)
    do {
      try Policy.validate(w, live: [21: changed])
      fatalError("PID reuse accepted")
    } catch {}
  }
  func testBackgroundAndAI() {
    let watcher = p(31, 10, "/opt/homebrew/bin/node", ["node", "tsc", "--watch"])
    precondition(Policy.workloads([31: watcher], ports: [:]).first?.kind.name == "Watcher")
    let ollama = p(
      32, 1, "/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"])
    precondition(Policy.workloads([32: ollama], ports: [32: [11434]]).first?.kind.name == "Ollama")
    let client = p(33, 1, "/usr/bin/java", ["java", "org.prismlauncher.EntryPoint"])
    precondition(Policy.workloads([33: client], ports: [33: [7881]]).isEmpty)
    let notebook = p(34, 10, "/opt/homebrew/bin/python3", ["python3", "-m", "jupyter", "lab"])
    precondition(
      Policy.workloads([34: notebook], ports: [34: [8888]]).first?.kind.name == "Jupyter")
  }
  func testGenerationAndNewChildren() throws {
    let shell = p(10, 1, "/bin/zsh", ["zsh"])
    let root = p(20, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    let child = Proc(
      pid: 21, parent: 20, parentUnique: 20, path: "/opt/homebrew/bin/node",
      args: ["node", "worker.js"])
    let all: [Int32: Proc] = [10: shell, 20: root, 21: child]
    let w = Policy.workloads(all, ports: [20: [3000]]).first!
    try Policy.validate(w, live: all)
    var live = all
    var altered = child
    altered.parentUnique = 999
    live[21] = altered
    do {
      try Policy.validate(w, live: live)
      fatalError("Parent generation drift accepted")
    } catch {}
    live = all
    live[22] = p(22, 20, "/bin/zsh", ["zsh"])
    do {
      try Policy.validate(w, live: live)
      fatalError("New protected child accepted")
    } catch {}
  }
  func testDedicatedWrapperBoundary() {
    let terminal = p(10, 1, "/bin/zsh", ["zsh"])
    let wrapper = p(11, 10, "/bin/sh", ["sh", "-c", "node server.js"])
    let node = p(12, 11, "/opt/homebrew/bin/node", ["node", "server.js"])
    let row = Policy.workloads([10: terminal, 11: wrapper, 12: node], ports: [12: [3000]]).first!
    precondition(row.root.pid == 11 && !row.members.contains { $0.pid == 10 })
    precondition(row.refusal == nil)
  }
  func testAppSupervisorAndNodePackageManager() {
    let gui = p(40, 1, "/Applications/Ollama.app/Contents/MacOS/Ollama", ["Ollama"])
    let service = p(
      41, 40, "/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"])
    precondition(
      Policy.workloads([40: gui, 41: service], ports: [41: [11434]]).first?.refusal != nil)
    let shell = p(10, 1, "/bin/zsh", ["zsh"])
    let npm = p(
      11, 10, "/opt/homebrew/bin/node",
      ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"])
    let wrapper = p(12, 11, "/bin/sh", ["sh", "-c", "next dev"])
    let server = p(
      13, 12, "/opt/homebrew/bin/node",
      ["node", "/tmp/project/node_modules/next/dist/bin/next", "dev"])
    let row = Policy.workloads([10: shell, 11: npm, 12: wrapper, 13: server], ports: [13: [3000]])
      .first!
    precondition(row.root.pid == 11 && row.members.count == 3 && row.refusal == nil)
  }

  func testShellSupervisorRefuses() {
    let supervisor = p(10, 1, "/bin/zsh", ["zsh", "-c", "while true; do node server.js; done"])
    let child = p(11, 10, "/opt/homebrew/bin/node", ["node", "server.js"])
    precondition(
      Policy.workloads([10: supervisor, 11: child], ports: [11: [3000]]).first?.refusal != nil)
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
        precondition(screen.contains(frame), "Panel would leave screen")
      }
    }
  }

}

@main struct Checks {
  static func main() throws {
    let t = PolicyTests()
    t.testSiblingAndShellBoundary()
    t.testInfrastructureAndGradleAreHidden()
    t.testMinecraftIsNotWeb()
    t.testProtectedDescendantRefuses()
    t.testDetachedIsNotAutomaticallyOrphan()
    try t.testPIDReuseRejected()
    try t.testGenerationAndNewChildren()
    t.testBackgroundAndAI()
    t.testDedicatedWrapperBoundary()
    t.testPanelWithinEveryScreen()
    t.testAppSupervisorAndNodePackageManager()
    t.testShellSupervisorRefuses()
    print("12 policy checks passed")
    if !CommandLine.arguments.contains("--policy-only") { try liveChecks() }
  }
}
