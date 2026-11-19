import AppKit
import BollardCore
import SwiftUI

/// The square at the head of a row: the application's own icon, or a symbol in the family colour.
struct Tile: View {
  private static let icons = NSCache<NSString, NSImage>()
  static func icon(_ bundle: String) -> NSImage {
    if let hit = icons.object(forKey: bundle as NSString) { return hit }
    let image = NSWorkspace.shared.icon(forFile: bundle)
    icons.setObject(image, forKey: bundle as NSString)
    return image
  }
  var w: Workload
  var body: some View {
    if w.section == .apps, let bundle = w.root.outerBundle {
      Image(nsImage: Self.icon(bundle)).resizable()
        .frame(width: 28, height: 28).accessibilityHidden(true)
    } else {
      let tint = Theme.tint(w)
      Image(systemName: w.kind.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
        .frame(width: 28, height: 28).background(tint.opacity(0.16), in: .rect(cornerRadius: 7))
        .accessibilityHidden(true)
    }
  }
}

struct Row: View {
  var store: Store
  var w: Workload
  @State private var hovering = false
  private var selected: Bool { store.selected == w.id }
  private var acting: Bool { store.acting.contains(w.id) }
  private var armed: Signal? { store.armed.flatMap { $0.id == w.id ? $0.signal : nil } }

  /// Kind, who started it and the branch.
  private var subtitle: Text {
    var parts: [Text] = []
    switch w.section {
    case .apps: parts.append(Text("Application"))
    case .system: parts.append(Text("macOS"))
    default:
      parts.append(Text(w.kind.name))
      if !["Detached", "Other", w.kind.name].contains(w.origin) { parts.append(Text(w.origin)) }
    }
    if let branch = w.branch {
      parts.append(Text("\(Image(systemName: "arrow.triangle.branch")) \(branch)"))
    }
    return parts.dropFirst().reduce(parts[0]) { Text("\($0) · \($1)") }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button {
          withAnimation(.snappy(duration: 0.2)) { store.select(w) }
        } label: {
          HStack(spacing: 10) {
            Tile(w: w)
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                if store.pinned(w) {
                  Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(store.name(w)).font(.system(size: 13, weight: .medium)).layoutPriority(1)
                if !w.detail.isEmpty, w.detail != w.name {
                  Text(w.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }.lineLimit(1)
              HStack(spacing: 5) {
                subtitle.foregroundStyle(.secondary).lineLimit(1)
                badges
              }.font(.system(size: 11))
            }
            Spacer(minLength: 4)
          }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(store.name(w)), \(w.detail), \(w.kind.name)\(w.ports.map { ", port \($0)" }.joined())"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        ports
        trailing
      }.padding(.horizontal, 8).padding(.vertical, 6)
      if selected { Detail(store: store, w: w) }
    }
    .background(
      selected
        ? AnyShapeStyle(.fill.quaternary)
        : hovering ? AnyShapeStyle(.fill.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
      in: .rect(cornerRadius: 10)
    )
    // A row sliding under a resting cursor is not being pointed at. Lighting each one up as it
    // passes rebuilds it mid-scroll.
    .onHover { hovering = $0 && !store.scrolling }
    .contextMenu { WorkloadMenu(store: store, w: w) }
  }
  @ViewBuilder private var badges: some View {
    if w.exposed, w.section == .servers {
      Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.orange)
        .help("Listening on all interfaces: reachable from your network")
        .accessibilityLabel("Reachable from your network")
    }
    if w.orphan {
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        .help("Its parent exited and left it running").accessibilityLabel("Orphaned")
    }
    if w.suspended { Text("suspended").foregroundStyle(.orange) }
  }
  @ViewBuilder private var ports: some View {
    let shown = w.ports.prefix(2)
    if !shown.isEmpty {
      HStack(spacing: 4) {
        ForEach(shown, id: \.self) { port in
          Button {
            if w.kind.web { store.open(port: port) } else { store.copy("\(port)") }
          } label: {
            Text(":\(String(port))").font(.system(size: 11, weight: .medium, design: .monospaced))
              .padding(.horizontal, 7).frame(height: 20)
              .foregroundStyle(
                w.exposed && w.section == .servers
                  ? AnyShapeStyle(.orange)
                  : w.blocked == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
              )
              .background(.fill.tertiary, in: .capsule).contentShape(.capsule)
          }
          .buttonStyle(.plain)
          .help(w.kind.web ? "Open http://localhost:\(String(port))" : "Copy \(String(port))")
          .accessibilityLabel("Port \(port)")
        }
        if w.ports.count > 2 {
          Text("+\(w.ports.count - 2)").font(.system(size: 10)).foregroundStyle(.tertiary)
            .help(w.ports.dropFirst(2).map { ":\(String($0))" }.joined(separator: " "))
        }
      }
    }
  }
  @ViewBuilder private var trailing: some View {
    if acting {
      ProgressView().controlSize(.small).frame(width: 62, alignment: .trailing)
    } else if let armed {
      Button(armed == .kill ? "Force Quit?" : w.section == .apps ? "Quit?" : "Stop?") {
        store.arm(w, armed)
      }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
    } else if store.lingering.contains(w.id) {
      Button("Force Quit") { store.arm(w, .kill) }.buttonStyle(.borderedProminent).tint(.red)
        .controlSize(.small)
    } else if hovering, w.blocked == nil {
      Button {
        store.arm(w, NSEvent.modifierFlags.contains(.option) ? .kill : .terminate)
      } label: {
        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 24, height: 24)
          .background(.fill.secondary, in: .circle).contentShape(.circle)
      }
      .buttonStyle(.plain).frame(width: 62, alignment: .trailing)
      .help("\(w.section == .apps ? "Quit" : "Stop") · hold ⌥ to force quit")
      .accessibilityLabel("\(w.section == .apps ? "Quit" : "Stop") \(store.name(w))")
    } else {
      VStack(alignment: .trailing, spacing: 2) {
        if w.members.isEmpty {
          Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
            .help(w.blocked ?? "")
        } else {
          Text(memoryText(w.memory))
            .foregroundStyle(
              w.memory >= 2_000_000_000 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          // Busy rows show their CPU; idle ones show how long they have been up.
          if w.cpu >= 1 {
            Text(String(format: "%.0f%% CPU", w.cpu))
              .foregroundStyle(w.cpu >= 80 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          } else {
            Text(uptimeText(w.uptime)).foregroundStyle(.tertiary)
          }
        }
      }
      .font(.system(size: 11)).monospacedDigit().frame(width: 62, alignment: .trailing)
      .accessibilityElement(children: .combine)
    }
  }
}
