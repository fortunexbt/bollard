import BollardCore
import Foundation

/// A server Bollard has seen and can launch again with the same command and directory.
struct RecentServer: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var kind: String
  var icon: String
  var ports: [Int]
  var directory: String
  var executable: String
  var arguments: [String]
  var origin: String
  var lastSeen: Date
  var command: String {
    ([executable] + arguments.dropFirst()).map(shellQuote).joined(separator: " ")
  }
}

/// Per-project preferences and the recent-server list, stored as JSON in Application Support.
@MainActor final class History {
  nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Bollard")
  private(set) var recent: [RecentServer] = []
  private(set) var pinned: Set<String> = []
  private(set) var names: [String: String] = [:]
  private struct Stored: Codable {
    var recent: [RecentServer]
    var pinned: [String]
    var names: [String: String]
  }
  private let file = History.folder.appendingPathComponent("history.json")

  init() {
    guard let data = try? Data(contentsOf: file),
      let stored = try? JSONDecoder().decode(Stored.self, from: data)
    else { return }
    recent = stored.recent
    pinned = Set(stored.pinned)
    names = stored.names
  }
  /// Stable key for a project: its directory plus executable, so a relaunch matches its past self.
  static func key(_ w: Workload) -> String { "\(w.root.cwd)\n\(w.root.path)" }

  func remember(_ w: Workload) {
    guard w.section == .servers || w.section == .background, w.restartReason == nil,
      !w.root.cwd.isEmpty
    else { return }
    let entry = RecentServer(
      id: History.key(w), name: w.name, kind: w.kind.name, icon: w.kind.icon, ports: w.ports,
      directory: w.root.cwd, executable: w.root.path, arguments: w.root.args, origin: w.origin,
      lastSeen: Date())
    recent.removeAll { $0.id == entry.id }
    recent.insert(entry, at: 0)
    if recent.count > 15 { recent.removeLast(recent.count - 15) }
    save()
  }
  func forget(_ id: String) {
    recent.removeAll { $0.id == id }
    save()
  }
  func togglePin(_ w: Workload) {
    let key = History.key(w)
    if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
    save()
  }
  func isPinned(_ w: Workload) -> Bool { pinned.contains(History.key(w)) }
  func rename(_ w: Workload, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == w.name {
      names[History.key(w)] = nil
    } else {
      names[History.key(w)] = trimmed
    }
    save()
  }
  func displayName(_ w: Workload) -> String { names[History.key(w)] ?? w.name }
  private func save() {
    try? FileManager.default.createDirectory(
      at: History.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stored = Stored(recent: recent, pinned: Array(pinned), names: names)
    if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
  }
}
