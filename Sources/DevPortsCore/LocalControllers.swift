import CryptoKit
import Foundation

/// Audited personal launchers. A changed file loses control privileges until reviewed.
public enum LocalControllers {
  private static let fingerprints = [
    "Brazil-Duo-4983089198474499673":
      "380c99351fc36d13f7c7ea389b5b2fbbc36582a27fc0301b4423ab4190a68cf6",
    "AgentCraft-Integration-Test":
      "385e2c2318593230be0b90bf042563abb295f43a013d480d542cd07547d54603",
  ]
  public static func isMinecraftController(_ p: Proc) -> Bool {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/PrismLauncher/servers")
    let directory = URL(fileURLWithPath: p.cwd).standardizedFileURL
    guard directory.deletingLastPathComponent() == base,
      let expected = fingerprints[directory.lastPathComponent],
      p.args.count == 3, p.args[2] == "run",
      URL(fileURLWithPath: p.args[1]).standardizedFileURL
        == directory.appendingPathComponent("control.py"),
      p.path.range(of: "/python.framework/", options: .caseInsensitive) != nil,
      let data = try? Data(contentsOf: directory.appendingPathComponent("control.py")),
      data.count < 64_000
    else { return false }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
  }
}
