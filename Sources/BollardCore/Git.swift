import Foundation

/// Branch or worktree name for a directory, from the checkout's HEAD file. No git binary involved.
public enum Git {
  nonisolated(unsafe) private static var cache: [String: (date: Date, branch: String?)] = [:]
  private static let lock = NSLock()

  public static func branch(for directory: String) -> String? {
    guard !directory.isEmpty else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[directory], Date().timeIntervalSince(hit.date) < 10 { return hit.branch }
    let value = read(directory)
    cache[directory] = (Date(), value)
    if cache.count > 500 { cache = cache.filter { Date().timeIntervalSince($0.value.date) < 60 } }
    return value
  }
  public static func read(_ directory: String) -> String? {
    var url = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<12 {
      let dotGit = url.appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
        var gitDirectory = dotGit
        var worktree: String?
        if !isDirectory.boolValue {
          // A worktree's .git is a file: "gitdir: /repo/.git/worktrees/<name>"
          guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
          else { return nil }
          let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
          gitDirectory = URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
          if gitDirectory.path.contains("/worktrees/") { worktree = gitDirectory.lastPathComponent }
        }
        guard
          let head = try? String(
            contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch =
          line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst(16)) : String(line.prefix(8))
        return worktree.map { $0 == branch ? branch : "\(branch) · \($0)" } ?? branch
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    return nil
  }
}
