import BollardCore
import Foundation

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0), so coding agents
/// can see and stop local servers without shelling out. Register it with
/// `claude mcp add -s user bollard -- bollard --mcp`.
enum MCPServer {
  static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  static var tools: [[String: Any]] {
    [
      [
        "name": "list_servers",
        "description":
          "List dev servers, background workloads, listening apps and system ports on this Mac, with ports, PIDs, directories, git branches, the agent or tool that started each one, and cautions. Optional query filters by name, port, PID, framework, branch or origin.",
        "annotations": [
          "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
          "openWorldHint": false,
        ],
        "inputSchema": [
          "type": "object",
          "properties": [
            "query": ["type": "string", "description": "Filter text, e.g. 3000, next, claude code"]
          ],
        ],
      ],
      [
        "name": "port_owner",
        "description":
          "Who is listening on a TCP port: process, PID, project directory, command and whether Bollard may stop it.",
        "annotations": [
          "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
          "openWorldHint": false,
        ],
        "inputSchema": [
          "type": "object", "properties": ["port": ["type": "integer"]], "required": ["port"],
        ],
      ],
      [
        "name": "free_port",
        "description":
          "Find a TCP port nobody is using, starting at the preferred port (default 3000) and counting up. Checks the loopback and wildcard addresses, so it works even when the process list is unavailable.",
        "annotations": [
          "readOnlyHint": true, "destructiveHint": false, "idempotentHint": false,
          "openWorldHint": false,
        ],
        "inputSchema": [
          "type": "object",
          "properties": [
            "start": ["type": "integer", "description": "First port to try, default 3000"]
          ],
        ],
      ],
      [
        "name": "wait_for_port",
        "description":
          "Block until a TCP port accepts connections (a server is ready) or, with state free, until it can be bound again (a server has exited). Returns reached true or false after at most timeout_seconds, default 30, capped at 120.",
        "annotations": [
          "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
          "openWorldHint": false,
        ],
        "inputSchema": [
          "type": "object",
          "properties": [
            "port": ["type": "integer"],
            "state": ["type": "string", "enum": ["listening", "free"]],
            "timeout_seconds": ["type": "number"],
          ], "required": ["port"],
        ],
      ],
      [
        "name": "stop_server",
        "description":
          "Stop a dev server or workload by port, PID or project name. Sends SIGTERM and waits 4 s by default; signal can be terminate, interrupt (Ctrl-C) or kill (SIGKILL). Reports exactly what exited and what is still running. Never touches agents, editors, terminals, shells or system processes.",
        "annotations": [
          "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false,
          "openWorldHint": false,
        ],
        "inputSchema": [
          "type": "object",
          "properties": [
            "target": ["type": "string", "description": "Port, PID or project directory name"],
            "signal": ["type": "string", "enum": ["terminate", "interrupt", "kill"]],
          ], "required": ["target"],
        ],
      ],
    ]
  }

  static func run() -> Never {
    let scanner = BollardCore.Scanner()
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty, let data = line.data(using: .utf8),
        let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      let id = message["id"]
      let method = message["method"] as? String ?? ""
      let params = message["params"] as? [String: Any] ?? [:]
      let response: [String: Any]?
      switch method {
      case "initialize":
        response = [
          "protocolVersion": protocolVersions.first { $0 == params["protocolVersion"] as? String }
            ?? protocolVersions[0],
          "capabilities": ["tools": [:]],
          "serverInfo": ["name": "bollard", "version": version],
        ]
      case "notifications/initialized", "notifications/cancelled": response = nil
      case "ping": response = [:]
      case "tools/list": response = ["tools": tools]
      case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        response = call(name, arguments, scanner)
      default:
        if let id {
          emit([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32601, "message": "Method not found: \(method)"],
          ])
        }
        continue
      }
      if let id, let response { emit(["jsonrpc": "2.0", "id": id, "result": response]) }
    }
    exit(0)
  }
  static func call(_ name: String, _ arguments: [String: Any], _ scanner: BollardCore.Scanner)
    -> [String: Any]
  {
    func text(_ s: String, error: Bool = false) -> [String: Any] {
      ["content": [["type": "text", "text": s]], "isError": error]
    }
    switch name {
    case "free_port":
      let start = arguments["start"] as? Int ?? 3000
      guard let port = Ports.firstFree(from: start) else {
        return text("No free port from \(start).", error: true)
      }
      return text(String(port))
    case "wait_for_port":
      guard let port = arguments["port"] as? Int, (1...Ports.dynamicEnd).contains(port) else {
        return text("port is required and must be 1-65535", error: true)
      }
      let listening = (arguments["state"] as? String ?? "listening") != "free"
      let timeout = min(max(arguments["timeout_seconds"] as? Double ?? 30, 0), 120)
      let reached = Ports.wait(for: port, listening: listening, timeout: timeout)
      return text(
        "{\"port\": \(port), \"state\": \"\(listening ? "listening" : "free")\", \"reached\": \(reached)}"
      )
    default: break
    }
    do {
      let scan = try scanner.scan()
      switch name {
      case "list_servers":
        let query = arguments["query"] as? String ?? ""
        let rows = scan.workloads.filter { query.isEmpty || CLI.matches(query, $0) }
        return text(rows.isEmpty ? "No matching workloads." : try CLI.json(rows))
      case "port_owner":
        guard let port = arguments["port"] as? Int else {
          return text("port is required", error: true)
        }
        let rows = scan.workloads.filter { $0.ports.contains(port) }
        if rows.isEmpty {
          return text(
            Ports.isListening(port)
              ? "Port \(port) is in use by a process Bollard cannot inspect: it belongs to root or another user."
              : "Nothing is listening on \(port).")
        }
        return text(try CLI.json(rows))
      case "stop_server":
        guard let target = arguments["target"] as? String else {
          return text("target is required", error: true)
        }
        let signal: Signal = {
          switch arguments["signal"] as? String {
          case "kill": return .kill
          case "interrupt": return .interrupt
          default: return .terminate
          }
        }()
        let result = CLI.stop(target, signal, in: scan)
        return text(result.report.joined(separator: "\n"), error: !result.found)
      default:
        return text("Unknown tool \(name)", error: true)
      }
    } catch {
      return text(error.localizedDescription, error: true)
    }
  }
  static func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
