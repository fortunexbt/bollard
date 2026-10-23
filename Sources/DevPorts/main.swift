import AppKit
import DevPortsCore
import ServiceManagement

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}
func describe(_ w: Workload) -> [String: Any] {
  [
    "name": w.name, "kind": w.kind.name, "section": w.section.rawValue, "pid": w.root.pid,
    "ports": w.ports,
    "listeners": w.listeners.map {
      ["address": $0.address, "port": $0.port, "wildcard": $0.wildcard, "pid": $0.pid]
    },
    "processes": w.members.map(\.pid), "memory": w.memory, "cpu": w.cpu, "uptime": Int(w.uptime),
    "provenance": w.provenance, "directory": w.root.cwd, "command": w.root.command,
    "cautions": w.cautions, "blocked": w.blocked ?? NSNull(), "launchd": w.launchdLabel ?? NSNull(),
    "exposed": w.exposed, "orphan": w.orphan,
  ]
}
/// Resolves a port, PID or project name to workloads the CLI may signal.
func targets(_ argument: String, in scan: Scan) -> [Workload] {
  let number = Int(argument)
  return scan.workloads.filter { w in
    if let number {
      return w.ports.contains(number) || w.members.contains { Int($0.pid) == number }
    }
    return w.name.localizedCaseInsensitiveCompare(argument) == .orderedSame
  }
}
let arguments = CommandLine.arguments
if arguments.contains("--login-status") {
  print(
    SMAppService.mainApp.status == .enabled
      ? "enabled" : "not enabled (status \(SMAppService.mainApp.status.rawValue))")
} else if arguments.contains("--list") || arguments.contains("--json") {
  do {
    let scan = try Scanner().scan()
    if arguments.contains("--json") {
      let data = try JSONSerialization.data(
        withJSONObject: scan.workloads.map(describe), options: [.prettyPrinted, .sortedKeys])
      print(String(decoding: data, as: UTF8.self))
    } else {
      for w in scan.workloads {
        let ports = Array(Set(w.listeners.map { "\($0.wildcard ? "*" : $0.address):\($0.port)" }))
          .sorted().joined(separator: ",")
        let state = w.blocked ?? (w.cautions.isEmpty ? "stoppable" : w.cautions[0])
        print(
          "\(w.section.rawValue)\t\(w.name)\t\(w.kind.name)\t\(ports)\t\(memoryText(w.memory))\tPID \(w.root.pid)\t\(w.provenance)\t\(state)"
        )
      }
      print(
        "\(scan.count) processes · \(scan.listeners.count) listeners · \(String(format: "%.1f", scan.duration * 1000)) ms"
      )
    }
  } catch { fail(error.localizedDescription) }
} else if let index = arguments.firstIndex(where: {
  $0 == "--stop" || $0 == "--kill" || $0 == "--interrupt"
}) {
  guard arguments.count > index + 1 else {
    fail("Usage: DevPorts --stop|--kill|--interrupt <port|pid|name>")
  }
  let signal: Signal =
    arguments[index] == "--kill"
    ? .kill : arguments[index] == "--interrupt" ? .interrupt : .terminate
  do {
    let scan = try Scanner().scan()
    let matches = targets(arguments[index + 1], in: scan)
    guard !matches.isEmpty else { fail("Nothing matches \(arguments[index + 1]).", code: 3) }
    var stillRunning = false
    for w in matches {
      if let blocked = w.blocked {
        print("\(w.name) (PID \(w.root.pid)): \(blocked)")
        stillRunning = true
        continue
      }
      let outcome = try Controller.stop(w, signal)
      if outcome.done {
        print(
          "\(signal.rawValue): \(w.name) (PID \(w.root.pid)) exited · \(outcome.signalled.count) process\(outcome.signalled.count == 1 ? "" : "es")"
        )
      } else {
        stillRunning = true
        print(
          "\(signal.rawValue): \(w.name) still running: \(outcome.remaining.map { "\($0.pid)" }.joined(separator: " "))"
        )
      }
    }
    exit(stillRunning ? 2 : 0)
  } catch { fail(error.localizedDescription) }
} else if arguments.contains("--help") || arguments.contains("-h") {
  print(
    """
    DevPorts — servers and background workloads on this Mac
      --list                  table of workloads
      --json                  the same as JSON
      --stop <port|pid|name>  SIGTERM the workload and wait up to 4 s
      --interrupt <target>    SIGINT, like Ctrl-C
      --kill <target>         SIGKILL
      --login-status          launch-at-login state
    Without arguments, runs the menu bar app.
    """)
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
