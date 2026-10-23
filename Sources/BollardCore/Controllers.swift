import CryptoKit
import Foundation

/// A user-declared supervisor script that knows how to shut its service down cleanly.
/// Stop signals the controller instead of the tree; it saves, backs up and exits on its own.
/// Declared in `~/Library/Application Support/Bollard/controllers.json`:
/// `{"controllers": [{"directory": "~/path", "script": "control.py", "sha256": "…", "label": "…"}]}`.
/// A controller whose script no longer matches its fingerprint loses the integration until the
/// fingerprint is updated, so an edited script is never trusted silently.
public struct ControllerScript: Equatable, Sendable {
  public var directory: URL
  public var script: String
  public var sha256: String
  public var label: String
  public var stopTimeout: TimeInterval
}

public enum Controllers {
  /// Overridable so checks can point at a disposable config.
  nonisolated(unsafe) public static var file = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Bollard/controllers.json")
  nonisolated(unsafe) private static var cached: (date: Date?, controllers: [ControllerScript]) = (
    nil, []
  )
  private static let lock = NSLock()

  /// Declared controllers, reread when the config file changes.
  public static func all() -> [ControllerScript] {
    lock.lock()
    defer { lock.unlock() }
    // FileManager, not URL.resourceValues: the URL caches attribute reads.
    let date =
      (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    if date == cached.date, date != nil { return cached.controllers }
    cached = (date, load())
    return cached.controllers
  }
  private static func load() -> [ControllerScript] {
    guard let data = try? Data(contentsOf: file),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = json["controllers"] as? [[String: Any]]
    else { return [] }
    return entries.compactMap { e in
      guard let directory = e["directory"] as? String, let script = e["script"] as? String,
        let sha = e["sha256"] as? String
      else { return nil }
      return ControllerScript(
        directory: URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
          .standardizedFileURL,
        script: script, sha256: sha.lowercased(),
        label: e["label"] as? String ?? "Controller · stops its service cleanly",
        stopTimeout: e["timeout"] as? TimeInterval ?? 60)
    }
  }
  /// The declared controller this process is, if its directory, arguments and script hash match.
  public static func match(_ p: Proc) -> ControllerScript? {
    guard !p.cwd.isEmpty, p.args.count == 3, p.args[2] == "run" else { return nil }
    let directory = URL(fileURLWithPath: p.cwd).standardizedFileURL
    guard let controller = all().first(where: { $0.directory == directory }) else { return nil }
    let script = directory.appendingPathComponent(controller.script)
    guard URL(fileURLWithPath: p.args[1]).standardizedFileURL == script,
      p.base.hasPrefix("python")
        || p.path.range(of: "/python.framework/", options: .caseInsensitive) != nil,
      let data = try? Data(contentsOf: script), data.count < 1_000_000
    else { return nil }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return hash == controller.sha256 ? controller : nil
  }
}
