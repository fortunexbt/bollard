import AppKit
import BollardCore
import SwiftUI

enum Theme {
  static let width: Double = 440
  static let radius: Double = 18
  /// One colour per family of workload, so a glance down the list sorts it.
  static func tint(_ w: Workload) -> Color {
    switch w.section {
    case .agents: return .orange
    case .apps: return .indigo
    case .system: return .gray
    case .servers, .background:
      switch w.kind.icon {
      case "cylinder.split.1x2": return .purple
      case "sparkles": return .pink
      case "puzzlepiece.extension", "arrow.left.arrow.right", "shippingbox": return .teal
      default: return w.section == .servers ? .blue : .green
      }
    }
  }
}

struct Panel: View {
  @Bindable var store: Store
  @FocusState private var searchFocused: Bool
  @State private var topHeight: Double = 0
  @State private var bottomHeight: Double = 0

  private var lanes: [(lane: Lane, rows: [Workload])] {
    let rows = Dictionary(grouping: store.rows, by: \.section)
    return Lane.allCases.compactMap { lane in rows[lane].map { (lane, $0) } }
  }
  var body: some View {
    let lanes = lanes
    let recent = store.search.isEmpty && store.filter == nil ? store.recent : []
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        header
        if store.origins.count > 1 { filters }
        banners
      }
      .onGeometryChange(for: Double.self) {
        $0.size.height
      } action: {
        topHeight = $0
        store.chromeHeight = topHeight + bottomHeight
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 2) {
            if lanes.isEmpty && recent.isEmpty { empty }
            ForEach(lanes, id: \.lane) { entry in
              laneHeader(entry.lane.rawValue, count: entry.rows.count)
              if store.open(entry.lane) {
                ForEach(entry.rows) { w in Row(store: store, w: w).id(w.id) }
              }
            }
            if !recent.isEmpty {
              laneHeader("Recent", count: recent.count)
              if !store.collapsed.contains("Recent") {
                ForEach(recent) { RecentRow(store: store, server: $0) }
              }
            }
          }
          .padding(.horizontal, 8).padding(.bottom, 8)
          .onGeometryChange(for: Double.self) {
            $0.size.height
          } action: {
            store.listHeight = $0
          }
        }
        .scrollIndicators(.automatic).frame(maxHeight: .infinity)
        .onChange(of: store.selected) { _, id in
          if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) } }
        }
      }
      footer.onGeometryChange(for: Double.self) {
        $0.size.height
      } action: {
        bottomHeight = $0
        store.chromeHeight = topHeight + bottomHeight
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: store.opened, initial: true) { searchFocused = true }
  }

  // MARK: Chrome

  var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search projects, ports, branches", text: $store.search)
          .textFieldStyle(.plain).focused($searchFocused).onSubmit { store.activate() }
          .accessibilityLabel("Search")
        if !store.search.isEmpty {
          Button {
            store.search = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }
      .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
      .background(.fill.tertiary, in: .capsule)
      Menu {
        menu
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
          .frame(width: 30, height: 30).background(.fill.tertiary, in: .circle)
          .contentShape(.circle)
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("More")
    }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
  }
  @ViewBuilder var menu: some View {
    Picker("Sort by", selection: $store.sort) {
      ForEach(WorkloadSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    Button("Refresh") { store.refresh() }.keyboardShortcut("r")
    Divider()
    let stoppable =
      store.scan?.workloads.contains { $0.section == .servers && $0.blocked == nil } ?? false
    Button(store.filter.map { "Stop All \($0) Servers" } ?? "Stop All Servers") {
      store.stopAll(.terminate)
    }.disabled(!stoppable)
    Button("Force Quit All Shown Servers") { store.stopAll(.kill) }.disabled(!stoppable)
    Divider()
    Toggle("Notify When Servers Start or Stop", isOn: $store.notify)
    Toggle("Global Shortcut \(Hotkey.description)", isOn: $store.hotkeyEnabled)
    Toggle("Launch at Login", isOn: $store.launchAtLogin)
    Divider()
    Button("Copy MCP Setup for Claude Code") {
      store.copy(
        "claude mcp add -s user bollard -- \(Bundle.main.executablePath ?? "bollard") --mcp",
        note: "MCP command copied. Paste it in a terminal.")
    }
    Button("Quit Bollard") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
  var filters: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        pill("All", count: nil, selected: store.filter == nil) { store.filter = nil }
        ForEach(store.origins, id: \.name) { origin in
          pill(origin.name, count: origin.count, selected: store.filter == origin.name) {
            store.filter = store.filter == origin.name ? nil : origin.name
          }
        }
      }.padding(.horizontal, 12)
    }.scrollIndicators(.hidden).padding(.bottom, 8)
  }
  func pill(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if let count { Text("\(count)").opacity(0.6) }
      }
      .font(.system(size: 11, weight: .medium)).monospacedDigit()
      .padding(.horizontal, 9).frame(height: 22)
      .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.quaternary), in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain).accessibilityLabel("Started by \(title)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  @ViewBuilder var banners: some View {
    if let error = store.error {
      Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
        .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
    if let notice = store.notice {
      HStack(alignment: .firstTextBaseline) {
        Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
        Spacer()
        Button {
          store.notice = nil
        } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Dismiss")
      }.padding(.horizontal, 16).padding(.bottom, 8)
    }
  }
  func laneHeader(_ title: String, count: Int) -> some View {
    let open = !store.collapsed.contains(title) || !store.search.isEmpty
    return Button {
      withAnimation(.snappy(duration: 0.2)) { store.toggle(title) }
    } label: {
      HStack(spacing: 5) {
        Text(title).foregroundStyle(.secondary)
        Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
          .foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
      }
      .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.top, 10)
      .padding(.bottom, 4).contentShape(.rect)
    }
    .buttonStyle(.plain).accessibilityLabel("\(title), \(count)")
    .accessibilityHint(open ? "Collapse" : "Expand")
  }
  var empty: some View {
    VStack(spacing: 6) {
      Image(systemName: store.search.isEmpty ? "moon.zzz" : "magnifyingglass")
        .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
      Text(store.search.isEmpty ? "Nothing running" : "No matches")
        .font(.system(size: 13, weight: .medium))
      Text(
        store.search.isEmpty
          ? "Servers, scripts and agents you start show up here."
          : "Nothing matches “\(store.search)”."
      ).font(.system(size: 11)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 28)
  }
  var footer: some View {
    HStack(spacing: 0) {
      if let scan = store.scan {
        Text("\(scan.count) processes · \(String(format: "%.0f", scan.duration * 1000)) ms")
      }
      Spacer()
      Text("↑↓ select · ⏎ open · ⌘⌫ stop")
    }
    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
    .padding(.horizontal, 16).frame(height: 26)
    .overlay(alignment: .top) { Divider().opacity(0.5) }
  }
}

/// A server that went away, one click from running again.
struct RecentRow: View {
  var store: Store
  var server: RecentServer
  @State private var hovering = false
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary).frame(width: 28, height: 28)
        .background(.fill.quaternary, in: .rect(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text("\(server.kind) · \(server.lastSeen.formatted(.relative(presentation: .named)))")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      if hovering {
        Button("Forget") { store.forget(server) }.buttonStyle(.plain).foregroundStyle(.secondary)
        Button("Launch") { store.launch(server) }.controlSize(.small)
      }
    }
    .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6)
    .background(
      hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear),
      in: .rect(cornerRadius: 10)
    )
    .onHover { hovering = $0 }.help(server.command)
    .accessibilityElement(children: .combine).accessibilityLabel("\(server.name), recent")
  }
}
