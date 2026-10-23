import DevPortsCore
import Foundation

/// Creates its own disposable servers, stops them, and proves siblings and shells survive.
func liveChecks() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "devports-check-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let js = dir.appendingPathComponent("server.js")
  try "require('http').createServer((q,s)=>s.end('DevPorts test')).listen(0,'127.0.0.1');".write(
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
