import AppKit
import BollardCore
import Foundation

/// Opens commands in a fresh Terminal window through a self-deleting .command file.
enum Launcher {
  static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

  static func open(directory: String, command: String) async throws {
    let folder = History.folder
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent("Launch-\(UUID().uuidString).command")
    let script =
      "#!/bin/zsh\n/bin/rm -- \"$0\"\ncd -- \(shellQuote(directory)) || exit 1\nexec \(command)\n"
    try script.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    _ = try await NSWorkspace.shared.open(
      [file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
  }
  static func relaunch(_ w: Workload) async throws {
    let command = ([w.root.path] + Array(w.root.args.dropFirst())).map(shellQuote).joined(
      separator: " ")
    try await open(directory: w.root.cwd, command: command)
  }
  static func relaunch(_ r: RecentServer) async throws {
    try await open(directory: r.directory, command: r.command)
  }
  /// Installed coding agents that can be started in a project directory.
  static var agents: [(name: String, path: String)] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let bins = [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
      "\(home)/.npm-global/bin",
    ]
    return [
      ("Claude Code", "claude"), ("Codex", "codex"), ("Gemini CLI", "gemini"),
      ("OpenCode", "opencode"), ("Aider", "aider"),
    ].compactMap { name, binary in
      bins.lazy.map { "\($0)/\(binary)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { (name, $0) }
    }
  }
  static func agent(_ path: String, in directory: String) async throws {
    try await open(directory: directory, command: shellQuote(path))
  }
  /// Editors and terminals installed on this Mac, for "Open in".
  static var editors: [String] {
    ["Visual Studio Code", "Cursor", "Zed", "Xcode", "Ghostty", "iTerm", "Warp", "Terminal"].filter
    {
      FileManager.default.fileExists(atPath: appPath($0))
    }
  }
  static func appPath(_ name: String) -> String {
    name == "Terminal" ? terminal.path : "/Applications/\(name).app"
  }
  static func openIn(_ name: String, _ folder: String) {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: folder)], withApplicationAt: URL(fileURLWithPath: appPath(name)),
      configuration: NSWorkspace.OpenConfiguration())
  }
  /// Markdown summary a user can paste into an agent prompt.
  static func agentContext(_ w: Workload, displayName: String) -> String {
    var lines = ["## \(displayName) (\(w.kind.name))"]
    if !w.ports.isEmpty {
      lines.append("- URL: " + w.ports.map { "http://localhost:\($0)" }.joined(separator: ", "))
    }
    lines.append(
      "- PID \(w.root.pid), \(w.members.count) process\(w.members.count == 1 ? "" : "es"), started by \(w.origin), up \(uptimeText(w.uptime))"
    )
    if !w.root.cwd.isEmpty {
      lines.append("- Directory: `\(w.root.cwd)`" + (w.branch.map { " on `\($0)`" } ?? ""))
    }
    if !w.root.command.isEmpty { lines.append("- Command: `\(w.root.command)`") }
    lines.append("- Memory \(memoryText(w.memory)), CPU \(String(format: "%.0f%%", w.cpu))")
    for l in w.listeners {
      lines.append(
        "- Listening on \(l.address):\(l.port)" + (l.wildcard ? " (all interfaces)" : ""))
    }
    for c in w.cautions { lines.append("- Note: \(c)") }
    lines.append(
      "- Stop it with: `bollard --stop \(w.ports.first.map(String.init) ?? String(w.root.pid))`")
    return lines.joined(separator: "\n")
  }
}
