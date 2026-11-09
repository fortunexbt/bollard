import AppKit
import BollardCore
import ServiceManagement

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}
let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let positional = arguments.filter { !$0.hasPrefix("--") }
if flags.contains("--help") || flags.contains("-h") {
  print(CLI.help)
} else if flags.contains("--version") {
  print(version)
} else if flags.contains("--mcp") {
  MCPServer.run()
} else if flags.contains("--login-status") {
  print(
    SMAppService.mainApp.status == .enabled
      ? "enabled" : "not enabled (status \(SMAppService.mainApp.status.rawValue))")
} else if flags.contains("--free-port") {
  guard let start = positional.first.map({ Int($0) }) ?? 3000, (1...65535).contains(start) else {
    fail("Usage: bollard --free-port [start-port]")
  }
  guard let port = Ports.firstFree(from: start) else {
    fail("No free port from \(start).", code: 3)
  }
  print(port)
} else if let wait = ["--wait-port": true, "--wait-free": false].first(where: {
  flags.contains($0.key)
}) {
  guard let port = positional.first.flatMap({ Int($0) }),
    let seconds = positional.dropFirst().first.map({ Double($0) }) ?? 30, seconds >= 0
  else { fail("Usage: bollard \(wait.key) <port> [seconds]") }
  let reached = Ports.wait(for: port, listening: wait.value, timeout: seconds)
  print(
    reached
      ? "Port \(port) is \(wait.value ? "accepting connections" : "free")."
      : "Timed out after \(String(format: "%g", seconds)) s, port \(port) is not \(wait.value ? "accepting connections" : "free")."
  )
  exit(reached ? 0 : 2)
} else if let action = ["--stop": Signal.terminate, "--interrupt": .interrupt, "--kill": .kill]
  .first(where: { flags.contains($0.key) })
{
  guard let target = positional.first else { fail("Usage: bollard \(action.key) <port|pid|name>") }
  do {
    let result = CLI.stop(target, action.value, in: try BollardCore.Scanner().scan())
    print(result.report.joined(separator: "\n"))
    exit(result.found ? (result.stillRunning ? 2 : 0) : 3)
  } catch { fail(error.localizedDescription) }
} else if flags.contains("--list") || flags.contains("--json") || !positional.isEmpty {
  do {
    let scan = try BollardCore.Scanner().scan()
    let query = positional.first ?? ""
    let rows = scan.workloads.filter { query.isEmpty || CLI.matches(query, $0) }
    if flags.contains("--json") {
      print(try CLI.json(rows))
    } else {
      if !rows.isEmpty { print(CLI.table(rows)) }
      print(
        "\(scan.count) processes · \(scan.listeners.count) listeners · \(String(format: "%.1f", scan.duration * 1000)) ms"
      )
    }
  } catch { fail(error.localizedDescription) }
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
