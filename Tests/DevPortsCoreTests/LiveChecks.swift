import DevPortsCore
import Foundation

func liveChecks() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "devports-check-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let js = dir.appendingPathComponent("server.js")
  try "require('http').createServer((q,s)=>s.end('DevPorts test')).listen(0,'127.0.0.1');".write(
    to: js, atomically: true, encoding: .utf8)
  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
  shell.currentDirectoryURL = dir
  shell.arguments = [
    "-c", "/opt/homebrew/bin/node server.js & /opt/homebrew/bin/node server.js & wait",
  ]
  shell.standardOutput = FileHandle.nullDevice
  shell.standardError = FileHandle.nullDevice
  try shell.run()
  var owned: [Proc] = []
  defer {
    for p in owned { try? Native.signal(p, SIGTERM) }
    if shell.isRunning { shell.terminate() }
    try? FileManager.default.removeItem(at: dir)
  }
  var rows: [Workload] = []
  for _ in 0..<30 {
    let all = Native.snapshot()
    owned = all.values.filter { $0.parent == shell.processIdentifier }
    rows = Policy.workloads(all, ports: try Native.listeners()).filter {
      $0.root.parent == shell.processIdentifier
    }
    if rows.count == 2 && rows.allSatisfy({ !$0.ports.isEmpty }) { break }
    Thread.sleep(forTimeInterval: 0.1)
  }
  precondition(rows.count == 2, "Both live sibling servers must be discovered")
  let a = rows[0]
  let b = rows[1]
  precondition(a.refusal == nil, a.refusal ?? "")
  let reused = Proc(
    pid: a.root.pid, parent: a.root.parent, start: a.root.identity.start + 1,
    unique: a.root.identity.unique, path: a.root.path, args: a.root.args)
  do {
    try Native.signal(reused, SIGTERM)
    fatalError("Stale identity accepted")
  } catch {}
  precondition(Native.read(a.root.pid)?.identity == a.id)
  try Controller.stop(a)
  precondition(Native.read(b.root.pid)?.identity == b.id, "Sibling was touched")
  precondition(shell.isRunning, "Parent shell was touched")
  let remaining = try Native.listeners()
  precondition(remaining[b.root.pid] != nil, "Sibling listener was lost")
  print(
    "Live checks passed: two real HTTP servers; stale identity rejected; selected server stopped; sibling and shell survived"
  )
}
