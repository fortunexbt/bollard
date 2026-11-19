import AppKit
import BollardCore

/// One thing the menu bar item can show beside the bollard. The user picks any of them.
enum Readout: String, CaseIterable {
  case servers, agents, cpu, memory, network
  var title: String {
    switch self {
    case .servers: return "Servers"
    case .agents: return "Agent Sessions"
    case .cpu: return "CPU"
    case .memory: return "Memory"
    case .network: return "Network"
    }
  }
  /// Readouts that need the system sampled on a timer of its own.
  var sampled: Bool { self == .cpu || self == .memory || self == .network }
}

enum MenuBar {
  /// The text beside the icon: a small caption and a value for each chosen readout. Digits are
  /// fixed-width and values are padded, so the item does not twitch as numbers change.
  static func title(
    _ readouts: Set<Readout>, servers: Int, exposed: Bool, agents: Int, system: SystemSample?
  ) -> NSAttributedString {
    let size = NSFont.menuBarFont(ofSize: 0).pointSize
    let value = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    let caption = NSFont.systemFont(ofSize: size - 4.5, weight: .semibold)
    let result = NSMutableAttributedString()
    func add(_ label: String, _ text: String, _ color: NSColor = .labelColor) {
      result.append(NSAttributedString(string: result.length == 0 ? " " : "   "))
      if !label.isEmpty {
        result.append(
          NSAttributedString(
            string: label.first?.isLetter == true ? label + " " : label,
            attributes: [
              .font: caption, .foregroundColor: NSColor.secondaryLabelColor, .baselineOffset: 1.5,
            ]))
      }
      result.append(
        NSAttributedString(string: text, attributes: [.font: value, .foregroundColor: color]))
    }
    // Figure spaces are as wide as digits, so a padded value keeps its width.
    func padded(_ text: String, _ width: Int) -> String {
      String(repeating: "\u{2007}", count: max(0, width - text.count)) + text
    }
    for readout in Readout.allCases where readouts.contains(readout) {
      switch readout {
      // The server count is only worth the space when something is serving; orange means one of
      // them is reachable from the network. The button itself is never tinted: that drops it out
      // of the menu bar's vibrant rendering and it draws black.
      case .servers: if servers > 0 { add("", "\(servers)", exposed ? .systemOrange : .labelColor) }
      case .agents: if agents > 0 { add("AI", "\(agents)") }
      case .cpu:
        guard let system else { continue }
        add(
          "CPU", padded(String(format: "%.0f%%", system.cpu), 3),
          system.cpu >= 90 ? .systemOrange : .labelColor)
      case .memory:
        guard let system, system.memoryTotal > 0 else { continue }
        let share = Double(system.memoryUsed) / Double(system.memoryTotal) * 100
        add(
          "MEM", padded(String(format: "%.0f%%", share), 3),
          share >= 90 ? .systemOrange : .labelColor)
      case .network:
        guard let system else { continue }
        add("↓", padded(compactBytes(system.received), 4))
        add("↑", padded(compactBytes(system.sent), 4))
      }
    }
    return result
  }
}
