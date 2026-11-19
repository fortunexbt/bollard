import BollardCore
import Foundation

let version = "3.0.2"

enum CLI {
  static func describe(_ w: Workload) -> [String: Any] {
    [
      "name": w.name, "runs": w.detail, "kind": w.kind.name, "section": w.section.rawValue,
      "pid": w.root.pid, "ports": w.ports,
      "listeners": w.listeners.filter { $0.transport != .unix }.map {
        [
          "address": $0.address, "port": $0.port, "wildcard": $0.wildcard, "pid": $0.pid,
          "transport": $0.transport.rawValue,
        ]
      },
      "sockets": w.listeners.filter { $0.transport == .unix }.map(\.path),
      "processes": w.members.map(\.pid), "memory": w.memory, "cpu": w.cpu, "uptime": Int(w.uptime),
      "provenance": w.provenance, "origin": w.origin, "branch": w.branch ?? NSNull(),
      "directory": w.root.cwd,
      "command": w.root.command, "cautions": w.cautions, "blocked": w.blocked ?? NSNull(),
      "launchd": w.launchdLabel ?? NSNull(), "exposed": w.exposed, "orphan": w.orphan,
      "url": w.url?.absoluteString ?? NSNull(),
    ]
  }
  /// Resolves a port, PID or project name to workloads that may be signalled.
  static func targets(_ argument: String, in scan: Scan) -> [Workload] {
    let number = Int(argument.hasPrefix(":") ? String(argument.dropFirst()) : argument)
    return scan.workloads.filter { w in
      if let number {
        return w.ports.contains(number) || w.members.contains { Int($0.pid) == number }
      }
      // A name never reaches an agent session; ending one takes its PID.
      return w.section != .agents
        && w.name.localizedCaseInsensitiveCompare(argument) == .orderedSame
    }
  }
  static func matches(_ query: String, _ w: Workload) -> Bool {
    "\(w.name) \(w.detail) \(w.kind.name) \(w.ports.map { ":\($0)" }.joined(separator: " ")) \(w.ports.map(String.init).joined(separator: " ")) \(w.origin) \(w.branch ?? "") \(w.root.pid) \(w.section.rawValue)"
      .localizedCaseInsensitiveContains(query)
  }
  static func table(_ workloads: [Workload]) -> String {
    var lines: [String] = []
    for w in workloads {
      let state = w.blocked ?? (w.cautions.isEmpty ? "stoppable" : w.cautions[0])
      lines.append(
        [
          w.section.rawValue, w.name, w.detail, w.kind.name,
          w.endpoints.joined(separator: ","), memoryText(w.memory),
          "PID \(w.root.pid)", w.origin + (w.branch.map { " · \($0)" } ?? ""), state,
        ].joined(separator: "\t"))
    }
    return lines.joined(separator: "\n")
  }
  static func json(_ workloads: [Workload]) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: workloads.map(describe), options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
  /// Signals matching workloads; returns a report and whether anything is still running.
  /// `agents` is false for the MCP server: one agent never ends another agent's session.
  static func stop(_ argument: String, _ signal: Signal, in scan: Scan, agents: Bool = true) -> (
    report: [String], stillRunning: Bool, found: Bool
  ) {
    let matches = targets(argument, in: scan)
    guard !matches.isEmpty else { return (["Nothing matches \(argument)."], false, false) }
    var report: [String] = []
    var stillRunning = false
    for w in matches {
      if w.section == .agents, !agents {
        report.append(
          "\(w.name) (PID \(w.root.pid)) is an agent session. Bollard's MCP server never ends one.")
        stillRunning = true
        continue
      }
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
    Bollard \(version) — servers, background jobs and agents running on this Mac
      bollard                        run the menu bar app
      bollard --list [query]         table of every lane, optionally filtered
      bollard --json [query]         the same as JSON, for scripts and agents
      bollard <query>                shorthand for --list <query>, e.g. `bollard 3000`
      bollard --stop <port|pid|name> SIGTERM, wait 4 s, exit 2 if still running
      bollard --interrupt <target>   SIGINT, like Ctrl-C
      bollard --kill <target>        SIGKILL
      bollard --free-port [start]    first free port from start (default 3000), exit 3 if none
      bollard --wait-port <port> [s] wait until the port accepts connections, exit 2 on timeout
      bollard --wait-free <port> [s] wait until the port can be bound again, exit 2 on timeout
      bollard --mcp                  Model Context Protocol server on stdio, for coding agents
      bollard --login-status         launch-at-login state
    """
}
