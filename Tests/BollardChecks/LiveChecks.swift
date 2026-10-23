import BollardCore
import Foundation

/// Creates its own disposable servers, stops them, and proves siblings and shells survive.
func liveChecks() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bollard-check-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let js = dir.appendingPathComponent("server.js")
  try "require('http').createServer((q,s)=>s.end('Bollard test')).listen(0,'127.0.0.1');".write(
    to: js, atomically: true, encoding: .utf8)
  let stubborn = dir.appendingPathComponent("stubborn.py")
  try """
  import signal, http.server
  signal.signal(signal.SIGTERM, signal.SIG_IGN)
  http.server.HTTPServer(('127.0.0.1', 0), http.server.BaseHTTPRequestHandler).serve_forever()
  """.write(to: stubborn, atomically: true, encoding: .utf8)
  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
  shell.currentDirectoryURL = dir
  shell.arguments = [
    "-c",
    "/opt/homebrew/bin/node server.js & /opt/homebrew/bin/node server.js & /usr/bin/python3 stubborn.py & wait",
  ]
  shell.standardOutput = FileHandle.nullDevice
  shell.standardError = FileHandle.nullDevice
  try shell.run()
  var owned: [Proc] = []
  // A failed precondition skips `defer`, so clean up explicitly before every failure.
  func cleanup() {
    for p in owned { try? Native.signal(p, SIGKILL) }
    if shell.isRunning { shell.terminate() }
    try? FileManager.default.removeItem(at: dir)
  }
  func require(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
      cleanup()
      fatalError("LiveChecks.swift:\(line): \(message())")
    }
  }
  defer { cleanup() }
  let scanner = Scanner()
  var rows: [Workload] = []
  for _ in 0..<100 {
    let scan = try scanner.scan()
    rows = scan.workloads.filter { $0.root.parent == shell.processIdentifier }
    owned = rows.flatMap(\.members)
    if rows.count == 3 && rows.allSatisfy({ !$0.ports.isEmpty }) { break }
    Thread.sleep(forTimeInterval: 0.2)
  }
  require(
    rows.count == 3, "All three fixture servers must be discovered, found \(rows.map(\.name))")
  require(
    rows.filter { $0.root.base.hasPrefix("python") }.count == 1,
    "roots: \(rows.map { ($0.root.base, $0.root.comm, $0.root.path, $0.kind.name) })")
  let nodes = rows.filter { $0.root.base == "node" }
  let python = rows.first { $0.root.base.hasPrefix("python") }!
  require(
    nodes.count == 2 && rows.allSatisfy { $0.blocked == nil && $0.cautions.isEmpty },
    "fixtures must be stoppable: \(rows.map { ($0.root.base, $0.root.path, $0.cautions, $0.blocked ?? "") })"
  )
  require(rows.allSatisfy { $0.section == .servers }, "fixtures are servers")
  let a = nodes[0]
  let b = nodes[1]
  let reused = Proc(
    pid: a.root.pid, parent: a.root.parent, start: a.root.identity.start + 1,
    unique: a.root.identity.unique, path: a.root.path, args: a.root.args)
  var staleRejected = false
  do { try Native.signal(reused, SIGTERM) } catch { staleRejected = true }
  require(staleRejected, "Stale identity accepted")
  let stopped = try Controller.stop(a, .terminate)
  require(stopped.done && stopped.signalled.count == 1, "SIGTERM stops a node server")
  require(Native.read(b.root.pid)?.identity == b.id, "Sibling was touched")
  require(shell.isRunning, "Parent shell was touched")
  let survivors = try Native.listeners()
  require(survivors.contains { $0.pid == b.root.pid }, "Sibling listener was lost")
  let ignored = try Controller.stop(python, .terminate)
  require(
    !ignored.done && ignored.remaining.map(\.pid) == [python.root.pid],
    "SIGTERM-ignoring server is reported as still running")
  let killed = try Controller.stop(python, .kill)
  require(killed.done, "SIGKILL ends it")
  require(shell.isRunning, "Parent shell survived stop and force quit of its children")
  let forced = try Controller.stop(b, .kill)
  require(forced.done, "Force quit the second node server")
  var exitedRejected = false
  do { _ = try Controller.stop(b, .terminate) } catch { exitedRejected = true }
  require(exitedRejected, "Stopping an exited workload must fail")
  print(
    "Live checks passed: three fixture servers; stale identity rejected; SIGTERM stop; SIGTERM-ignoring server reported, then force quit; siblings and shell survived"
  )
}

/// A user launch agent, a scripted .app bundle and a stop-all run, each with its own fixture.
func serviceChecks() throws {
  let uid = getuid()
  let label = "com.fortunexbt.bollard.check"
  let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/LaunchAgents")
  let plist = agents.appendingPathComponent("\(label).plist")
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bollard-service-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  func cleanup() {
    _ = try? Native.output("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 10)
    try? FileManager.default.removeItem(at: plist)
    _ = try? Native.output("/usr/bin/pkill", ["-9", "-f", "http.server 18451"], timeout: 5)
    _ = try? Native.output("/usr/bin/pkill", ["-9", "-x", "check"], timeout: 5)
    try? FileManager.default.removeItem(at: dir)
  }
  func require(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
      cleanup()
      fatalError("LiveChecks.swift:\(line): \(message())")
    }
  }
  defer { cleanup() }
  // 1. launchd: a disposable agent must show its label and unload for good.
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  try """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
  <key>Label</key><string>\(label)</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-m</string><string>http.server</string><string>18451</string><string>--bind</string><string>127.0.0.1</string></array>
  <key>WorkingDirectory</key><string>\(dir.path)</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  </dict></plist>
  """.write(to: plist, atomically: true, encoding: .utf8)
  _ = try Native.output("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path], timeout: 10)
  let scanner = Scanner()
  var agent: Workload?
  for _ in 0..<50 {
    agent = try scanner.scan().workloads.first { $0.ports.contains(18451) }
    if agent?.launchdLabel == label { break }
    Thread.sleep(forTimeInterval: 0.2)
  }
  require(
    agent?.launchdLabel == label,
    "launch agent discovered with its label: \(String(describing: agent?.launchdLabel))")
  require(
    agent?.blocked == nil && agent?.cautions.first?.contains("launchd may restart it") == true,
    "launchd caution: \(agent?.cautions ?? [])")
  require(agent?.origin == "launchd", agent?.origin ?? "nil")
  try Controller.unloadLaunchAgent(label)
  let gone = Controller.wait(for: agent!.members, upTo: 5)
  require(gone.isEmpty, "unload stops the agent's server")
  let listing = try Native.output("/bin/launchctl", ["list"], timeout: 5)
  require(!listing.contains(label), "agent is no longer registered")
  // 2. An application bundle whose process listens: Apps lane, merged under the bundle name.
  let app = dir.appendingPathComponent("Bollard Check.app")
  try FileManager.default.createDirectory(
    at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
  try """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>check</string>
  <key>CFBundleIdentifier</key><string>com.fortunexbt.bollard.checkapp</string>
  <key>CFBundleName</key><string>Bollard Check</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  </dict></plist>
  """.write(
    to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
  // A real Mach-O inside the bundle, so the listening process is the application itself.
  let source = dir.appendingPathComponent("check.c")
  try """
  #include <netinet/in.h>
  #include <sys/socket.h>
  #include <unistd.h>
  int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET; a.sin_port = htons(18452); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(s, (struct sockaddr *)&a, sizeof a); listen(s, 4);
    for (;;) { int c = accept(s, 0, 0); if (c >= 0) close(c); }
  }
  """.write(to: source, atomically: true, encoding: .utf8)
  let executable = app.appendingPathComponent("Contents/MacOS/check")
  _ = try Native.output("/usr/bin/clang", ["-O1", "-o", executable.path, source.path], timeout: 60)
  _ = try Native.output("/usr/bin/open", ["-a", app.path], timeout: 10)
  var row: Workload?
  for _ in 0..<50 {
    row = try scanner.scan().workloads.first { $0.ports.contains(18452) }
    if row != nil { break }
    Thread.sleep(forTimeInterval: 0.2)
  }
  require(
    row?.section == .apps && row?.name == "Bollard Check" && row?.blocked == nil,
    "scripted app is an App row: \(String(describing: row?.section)) \(row?.name ?? "")")
  require(row?.restartReason != nil, "apps do not restart from Terminal")
  let forced = try Controller.stop(row!, .kill)
  require(forced.done, "force quit ends the app's tree")
  // 3. Stop all: three fixture servers, one call.
  let js = dir.appendingPathComponent("server.js")
  try "require('http').createServer((q,s)=>s.end('ok')).listen(0,'127.0.0.1');".write(
    to: js, atomically: true, encoding: .utf8)
  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
  shell.currentDirectoryURL = dir
  shell.arguments = [
    "-c",
    "/opt/homebrew/bin/node server.js & /opt/homebrew/bin/node server.js & /opt/homebrew/bin/node server.js & wait",
  ]
  shell.standardOutput = FileHandle.nullDevice
  shell.standardError = FileHandle.nullDevice
  try shell.run()
  defer { if shell.isRunning { shell.terminate() } }
  var rows: [Workload] = []
  for _ in 0..<100 {
    rows = try scanner.scan().workloads.filter {
      $0.root.parent == shell.processIdentifier && !$0.ports.isEmpty
    }
    if rows.count == 3 { break }
    Thread.sleep(forTimeInterval: 0.2)
  }
  require(rows.count == 3, "three fixture servers for stop all, found \(rows.count)")
  let results = Controller.stopAll(rows, .terminate)
  require(results.count == 3, "one result per workload")
  for (_, result) in results {
    guard case .success(let outcome) = result, outcome.done else {
      require(false, "stop all left something running: \(result)")
      continue
    }
  }
  print(
    "Service checks passed: launch agent discovered, cautioned and unloaded; scripted .app listed under Apps and force quit; stop all ended three servers"
  )
}
