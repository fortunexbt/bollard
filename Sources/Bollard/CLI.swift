import BollardCore
import Foundation

let version = "2.1.0"

enum CLI {
  static func describe(_ w: Workload) -> [String: Any] {
    [
      "name": w.name, "kind": w.kind.name, "section": w.section.rawValue, "pid": w.root.pid,
      "ports": w.ports,
      "listeners": w.listeners.map {
        ["address": $0.address, "port": $0.port, "wildcard": $0.wildcard, "pid": $0.pid]
      },
      "processes": w.members.map(\.pid), "memory": w.memory, "cpu": w.cpu, "uptime": Int(w.uptime),
      "provenance": w.provenance, "origin": w.origin, "branch": w.branch ?? NSNull(),
      "directory": w.root.cwd,
      "command": w.root.command, "cautions": w.cautions, "blocked": w.blocked ?? NSNull(),
      "launchd": w.launchdLabel ?? NSNull(), "exposed": w.exposed, "orphan": w.orphan,
    ]
  }
  /// Resolves a port, PID or project name to workloads that may be signalled.
  static func targets(_ argument: String, in scan: Scan) -> [Workload] {
    let number = Int(argument.hasPrefix(":") ? String(argument.dropFirst()) : argument)
    return scan.workloads.filter { w in
      if let number {
        return w.ports.contains(number) || w.members.contains { Int($0.pid) == number }
      }
      return w.name.localizedCaseInsensitiveCompare(argument) == .orderedSame
    }
  }
  static func matches(_ query: String, _ w: Workload) -> Bool {
    "\(w.name) \(w.kind.name) \(w.ports.map { ":\($0)" }.joined(separator: " ")) \(w.ports.map(String.init).joined(separator: " ")) \(w.origin) \(w.branch ?? "") \(w.root.pid) \(w.section.rawValue)"
      .localizedCaseInsensitiveContains(query)
  }
  static func table(_ workloads: [Workload]) -> String {
    var lines: [String] = []
    for w in workloads {
      let ports = Array(Set(w.listeners.map { "\($0.wildcard ? "*" : $0.address):\($0.port)" }))
        .sorted().joined(separator: ",")
      let state = w.blocked ?? (w.cautions.isEmpty ? "stoppable" : w.cautions[0])
      lines.append(
        "\(w.section.rawValue)\t\(w.name)\t\(w.kind.name)\t\(ports)\t\(memoryText(w.memory))\tPID \(w.root.pid)\t\(w.origin)\(w.branch.map { " · \($0)" } ?? "")\t\(state)"
      )
    }
    return lines.joined(separator: "\n")
  }
  static func json(_ workloads: [Workload]) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: workloads.map(describe), options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
  /// Signals matching workloads; returns a report and whether anything is still running.
  static func stop(_ argument: String, _ signal: Signal, in scan: Scan) -> (
    report: [String], stillRunning: Bool, found: Bool
  ) {
    let matches = targets(argument, in: scan)
    guard !matches.isEmpty else { return (["Nothing matches \(argument)."], false, false) }
    var report: [String] = []
    var stillRunning = false
    for w in matches {
      if let blocked = w.blocked {
        report.append("\(w.name) (PID \(w.root.pid)): \(blocked)")
        stillRunning = true
        continue
      }
      do {
        let outcome = try Controller.stop(w, signal)
        if outcome.done {
          report.append(
            "\(signal.rawValue): \(w.name) (PID \(w.root.pid)) exited · \(outcome.signalled.count) process\(outcome.signalled.count == 1 ? "" : "es")"
          )
        } else {
          stillRunning = true
          report.append(
            "\(signal.rawValue): \(w.name) still running: \(outcome.remaining.map { "\($0.pid)" }.joined(separator: " "))"
          )
        }
      } catch {
        stillRunning = true
        report.append("\(w.name): \(error.localizedDescription)")
      }
    }
    return (report, stillRunning, true)
  }
  static let help = """
    Bollard \(version) — servers and background workloads on this Mac
      bollard                        run the menu bar app
      bollard --list [query]         table of every lane, optionally filtered
      bollard --json [query]         the same as JSON, for scripts and agents
      bollard <query>                shorthand for --list <query>, e.g. `bollard 3000`
      bollard --stop <port|pid|name> SIGTERM, wait 4 s, exit 2 if still running
      bollard --interrupt <target>   SIGINT, like Ctrl-C
      bollard --kill <target>        SIGKILL
      bollard --mcp                  Model Context Protocol server on stdio, for coding agents
      bollard --login-status         launch-at-login state
    """
}
