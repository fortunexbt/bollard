import Foundation

/// Runs the built `Bollard` next to this checks binary, so the CLI flags and MCP framing are
/// exercised as agents call them rather than through the library.
func binaryChecks() throws {
  let binary = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
    "Bollard")
  func run(_ arguments: [String], input: String = "") throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  let free = try run(["--free-port", "41000"])
  let port = Int(free.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  precondition(free.status == 0 && port >= 41000, "--free-port: \(free)")
  let timedOut = try run(["--wait-port", String(port), "0.3"])
  precondition(timedOut.status == 2, "--wait-port on a free port must exit 2: \(timedOut)")
  let none = try run(["--free-port", "70000"])
  precondition(none.status == 1, "--free-port above 65535 is bad usage: \(none)")

  let requests = [
    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"free_port","arguments":{"start":41000}}}"#,
    #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wait_for_port","arguments":{"port":\#(port),"state":"free","timeout_seconds":1}}}"#,
    #"{"jsonrpc":"2.0","id":5,"method":"nope"}"#,
  ]
  let mcp = try run(["--mcp"], input: requests.joined(separator: "\n") + "\n")
  precondition(mcp.status == 0, "--mcp exit \(mcp.status)")
  var replies: [Int: [String: Any]] = [:]
  for line in mcp.output.split(separator: "\n") {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    replies[object["id"] as! Int] = object
  }
  precondition(replies.count == 5, "one reply per request with an id, none for notifications")
  let initialize = replies[1]?["result"] as? [String: Any]
  precondition(initialize?["protocolVersion"] as? String == "2025-06-18", "negotiated version")
  let tools = (replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
  let names = Set(tools.compactMap { $0["name"] as? String })
  precondition(
    names == ["list_servers", "port_owner", "stop_server", "free_port", "wait_for_port"],
    "tools: \(names)")
  precondition(tools.allSatisfy { $0["annotations"] != nil }, "every tool carries annotations")
  func text(_ id: Int) -> String {
    let result = replies[id]?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String ?? ""
  }
  precondition(Int(text(3)).map { $0 >= 41000 } == true, "free_port: \(text(3))")
  precondition(text(4).contains("\"reached\": true"), "wait_for_port free: \(text(4))")
  precondition(
    (replies[5]?["error"] as? [String: Any])?["code"] as? Int == -32601, "unknown method error")
  print("Binary checks passed: --free-port, --wait-port timeout, MCP initialize, tools, calls")
}
