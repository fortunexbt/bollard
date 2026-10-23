import BollardCore
import SwiftUI

struct Sparkline: View {
  var samples: [Double]
  var color: Color
  var body: some View {
    Canvas { context, size in
      guard samples.count > 1 else { return }
      let top = max(100, samples.max() ?? 0)
      var path = Path()
      for (i, v) in samples.enumerated() {
        let x = size.width * Double(i) / Double(samples.count - 1)
        let y = size.height - (size.height - 1) * min(1, v / top)
        if i == 0 {
          path.move(to: CGPoint(x: x, y: y))
        } else {
          path.addLine(to: CGPoint(x: x, y: y))
        }
      }
      context.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
      var fill = path
      fill.addLine(to: CGPoint(x: size.width, y: size.height))
      fill.addLine(to: CGPoint(x: 0, y: size.height))
      fill.closeSubpath()
      context.fill(
        fill,
        with: .linearGradient(
          Gradient(colors: [color.opacity(0.25), color.opacity(0)]), startPoint: .zero,
          endPoint: CGPoint(x: 0, y: size.height)))
    }
  }
}

struct Row: View {
  @ObservedObject var store: Store
  var w: Workload
  var acting: Bool
  @State private var hovering = false
  var armed: Signal? { store.armed.flatMap { $0.id == w.id ? $0.signal : nil } }
  var subtitle: String {
    var parts = [w.kind.name]
    if let branch = w.branch { parts.append(branch) }
    if w.section == .servers || w.section == .background { parts.append(w.origin) }
    return parts.joined(separator: " · ")
  }
  var body: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          store.selected = store.selected == w.id ? nil : w.id
          store.armed = nil
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: w.kind.icon).font(.system(size: 15))
            .foregroundStyle(w.orphan ? .orange : w.section == .system ? .secondary : accent)
            .frame(width: 28, height: 30).background(
              (w.section == .system ? Color.secondary : accent).opacity(0.1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
              if store.pinned(w) {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
              }
              Text(store.name(w)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
              if w.exposed {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 9))
                  .foregroundStyle(.orange)
                  .help("Listening on all interfaces")
              }
              if w.suspended { Text("suspended").font(.system(size: 9)).foregroundStyle(.orange) }
              if w.orphan {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
                  .foregroundStyle(.orange)
              }
            }
            HStack(spacing: 5) {
              Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
              if w.launchdLabel != nil {
                Image(systemName: "gearshape").foregroundStyle(.tertiary).help(w.launchdLabel ?? "")
              }
            }.font(.system(size: 10))
          }
          Spacer(minLength: 4)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(
          "\(store.name(w)), \(w.kind.name)\(w.ports.map { ", port \($0)" }.joined())")
      if !w.ports.isEmpty {
        HStack(spacing: 3) {
          ForEach(w.ports.prefix(3), id: \.self) { port in
            Button(":\(port)") {
              if w.kind.web { store.open(port: port) } else { store.copy("\(port)") }
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(accent)
            .padding(.horizontal, 5).padding(.vertical, 2).background(accent.opacity(0.1))
            .clipShape(Capsule())
            .help(w.kind.web ? "Open http://localhost:\(port)" : "Copy \(port)").accessibilityLabel(
              "Port \(port)")
          }
          if w.ports.count > 3 {
            Text("+\(w.ports.count - 3)").font(.system(size: 9)).foregroundStyle(.tertiary)
          }
        }
      }
      if hovering || armed != nil || acting {
        actionButton
      } else {
        Sparkline(samples: w.history.map(\.cpu), color: accent).frame(width: 40, height: 14)
          .opacity(w.history.contains { $0.cpu >= 0.5 } ? 1 : 0)
        Text(String(format: "%.0f%%", w.cpu)).frame(width: 32, alignment: .trailing)
        Text(memoryText(w.memory)).foregroundStyle(w.memory >= 2_000_000_000 ? .orange : .primary)
          .frame(width: 58, alignment: .trailing)
        Text(uptimeText(w.uptime)).foregroundStyle(.secondary).frame(
          width: 46, alignment: .trailing)
      }
    }.font(.system(size: 11, design: .monospaced)).monospacedDigit().padding(.horizontal, 10)
      .padding(.vertical, 8)
      .onHover { hovering = $0 }
  }
  @ViewBuilder var actionButton: some View {
    HStack(spacing: 6) {
      if acting {
        ProgressView().controlSize(.small)
        Text("Stopping…").foregroundStyle(.secondary)
      } else if let blocked = w.blocked {
        Label("read only", systemImage: "lock").foregroundStyle(.tertiary).help(blocked)
      } else if let armed {
        Button(armed == .kill ? "Force quit?" : (w.section == .apps ? "Quit?" : "Stop?")) {
          store.arm(w, armed)
        }
        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small).keyboardShortcut(
          .defaultAction)
        Button("Cancel") { store.armed = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
      } else if store.lingering.contains(w.id) {
        Button("Force Quit") { store.arm(w, .kill) }.buttonStyle(.borderedProminent).tint(.red)
          .controlSize(.small)
      } else {
        Button {
          store.arm(w, NSEvent.modifierFlags.contains(.option) ? .kill : .terminate)
        } label: {
          Label(w.section == .apps ? "Quit" : "Stop", systemImage: "xmark.circle.fill")
        }.buttonStyle(.bordered).controlSize(.small).help("Stop · ⌥ for Force Quit")
          .accessibilityLabel("Stop \(store.name(w))")
      }
    }.frame(width: 190, alignment: .trailing)
  }
}
