import AppKit
import BollardCore
import ServiceManagement
import SwiftUI

let accent = Color(red: 0.25, green: 0.63, blue: 0.95)

struct HeightKey: PreferenceKey {
  static let defaultValue: Double = 0
  static func reduce(value: inout Double, nextValue: () -> Double) {
    value = max(value, nextValue())
  }
}
extension View {
  /// Reports the view's laid-out height so the panel can size itself to its content.
  func measured(_ update: @escaping (Double) -> Void) -> some View {
    background(
      GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) }
    )
    .onPreferenceChange(HeightKey.self) { value in Task { @MainActor in update(value) } }
  }
}

struct Panel: View {
  @ObservedObject var store: Store
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        header
        if store.compact {
          HStack(spacing: 9) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text("All quiet").font(.system(size: 13, weight: .medium))
              Text("No dev servers or background workloads.").font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
          }.padding(.horizontal, 14).padding(.top, 3).padding(.bottom, 14)
        } else {
          stats
          searchField
          if store.origins.count > 1 { originPills }
          if let error = store.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
              .foregroundStyle(.orange)
              .padding(.horizontal, 20).padding(.bottom, 8)
          }
          if let notice = store.notice {
            HStack {
              Text(notice).font(.system(size: 11)).lineLimit(3)
              Spacer()
              Button {
                store.notice = nil
              } label: {
                Image(systemName: "xmark")
              }.buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }.padding(.horizontal, 14).padding(.bottom, 7)
          }
        }
      }.measured { store.chromeHeight = $0 }
      if !store.compact {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 4) {
              ForEach(Lane.allCases, id: \.self) { section in laneView(section) }
              recentLane
            }.padding(.horizontal, 9).padding(.bottom, 8).measured { store.listHeight = $0 }
          }.defaultScrollAnchor(.top).scrollIndicators(.automatic).frame(maxHeight: .infinity)
            .onChange(of: store.selected) { _, id in
              if let id { withAnimation { proxy.scrollTo(id, anchor: nil) } }
            }
        }
        Divider()
        footer
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: searchFocused) { _, focused in store.searchFocused = focused }
  }
  var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "point.3.connected.trianglepath.dotted").font(
        .system(size: 17, weight: .medium)
      ).foregroundStyle(accent)
      Text("Bollard").font(.system(size: 14, weight: .semibold))
      Spacer()
      if !store.compact {
        Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
        Text(store.busy ? "Scanning" : "Live").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Button {
        store.refresh()
      } label: {
        Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless).help("Refresh · ⌘R").accessibilityLabel("Refresh")
      Menu {
        Picker("Sort by", selection: $store.sort) {
          ForEach(WorkloadSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Button(store.filter.map { "Stop all \($0) servers" } ?? "Stop all servers") {
          store.stopAll(.terminate)
        }
        .disabled(store.servers.allSatisfy { $0.blocked != nil })
        Button("Force quit all shown servers") { store.stopAll(.kill) }.disabled(
          store.servers.allSatisfy { $0.blocked != nil })
        Divider()
        Toggle("Notify when servers start or stop", isOn: $store.notify)
        Toggle("Global shortcut \(Hotkey.description)", isOn: $store.hotkeyEnabled)
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
              do {
                enabled
                  ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
              } catch { store.error = error.localizedDescription }
            }))
        Divider()
        Button("Copy MCP setup for Claude Code") {
          store.copy(
            "claude mcp add -s user bollard -- \(Bundle.main.executablePath ?? "bollard") --mcp",
            note: "MCP command copied. Paste it in a terminal.")
        }
        Button("Quit Bollard") { NSApp.terminate(nil) }.keyboardShortcut("q")
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel(
        "More")
    }.padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)
  }
  var stats: some View {
    let servers = store.scan?.workloads.filter { $0.section == .servers } ?? []
    let exposed = servers.filter(\.exposed).count
    return HStack(spacing: 7) {
      Text("\(servers.count) server\(servers.count == 1 ? "" : "s")")
      Text("·")
      Text("\(store.scan?.listeners.count ?? 0) ports")
      Text("·")
      Text(memoryText(servers.reduce(0) { $0 + $1.memory }))
      Text("·")
      Text(String(format: "%.0f%% CPU", servers.reduce(0) { $0 + $1.cpu }))
      if exposed > 0 {
        Text("·")
        Label("\(exposed) on LAN", systemImage: "antenna.radiowaves.left.and.right")
          .foregroundStyle(.orange)
      }
      Spacer()
    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).padding(.horizontal, 14)
      .padding(.bottom, 7)
  }
  var searchField: some View {
    HStack {
      Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
      TextField("Find a server, project, port, branch or PID", text: $store.search).textFieldStyle(
        .plain
      )
      .font(.system(size: 12)).focused($searchFocused).accessibilityLabel("Search")
      if !store.search.isEmpty {
        Button {
          store.search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }.buttonStyle(.plain)
          .accessibilityLabel("Clear search")
      } else {
        Text("⌘F").font(.system(size: 9, weight: .medium)).foregroundStyle(.quaternary)
      }
    }.padding(7).background(.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 9))
      .padding(.horizontal, 10).padding(.bottom, 8)
  }
  /// One pill per launcher. Selecting one scopes the list and "Stop all" to that launcher.
  var originPills: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 5) {
        pill("All", count: nil, selected: store.filter == nil) { store.filter = nil }
        ForEach(store.origins, id: \.name) { origin in
          pill(origin.name, count: origin.count, selected: store.filter == origin.name) {
            store.filter = store.filter == origin.name ? nil : origin.name
          }
        }
      }.padding(.horizontal, 12)
    }.scrollIndicators(.never).padding(.bottom, 8)
  }
  func pill(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        if let count {
          Text("\(count)").foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
        }
      }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? accent : Color.primary.opacity(0.06)).foregroundStyle(
          selected ? .white : .primary
        )
        .clipShape(Capsule())
    }.buttonStyle(.plain).accessibilityLabel("Filter \(title)")
  }
  var footer: some View {
    HStack {
      Text(
        store.scan.map {
          "\($0.count) processes · \(String(format: "%.1f", $0.duration * 1000)) ms"
            + ($0.usedSocketFallback ? " · lsof fallback" : "")
        } ?? "Reading your Mac…")
      Spacer()
      Text("⌘⌫ stop · ⌘⇧⌫ force · ⌘O open · ⌘P pin").foregroundStyle(.quaternary)
      Image(systemName: "lock.shield")
    }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(
      .vertical, 8)
  }

  @ViewBuilder func laneView(_ section: Lane) -> some View {
    let rows = store.lane(section)
    let open = section == .servers || store.open(section)
    if section == .servers {
      HStack {
        Text(section.rawValue.uppercased()).tracking(1.3)
        Spacer()
        Text("CPU").frame(width: 76, alignment: .trailing)
        Text("MEMORY").frame(width: 58, alignment: .trailing)
        Text("UPTIME").frame(width: 46, alignment: .trailing)
      }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(
        .horizontal, 14
      ).padding(.vertical, 5)
      ForEach(rows) { row($0) }
      if rows.isEmpty { empty }
    } else if !rows.isEmpty || section == .background {
      laneHeader(section.rawValue, count: rows.count, open: open) {
        if section == .background, rows.contains(where: { $0.orphan }) {
          Label("Orphaned", systemImage: "exclamationmark.circle.fill").font(.system(size: 10))
            .foregroundStyle(.orange)
        }
        if section == .system {
          Text("read only").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
      }
      if open {
        ForEach(rows) { row($0) }
        if rows.isEmpty {
          Text("No background workloads").font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(10)
        }
      }
    }
  }
  @ViewBuilder var recentLane: some View {
    let recent = store.recent
    if !recent.isEmpty, store.filter == nil, store.search.isEmpty {
      laneHeader("Recent", count: recent.count, open: !store.collapsed.contains("Recent")) {
        Text("launch again").font(.system(size: 10)).foregroundStyle(.tertiary)
      }
      if !store.collapsed.contains("Recent") {
        ForEach(recent) { r in RecentRow(store: store, r: r) }
      }
    }
  }
  func laneHeader<Trailing: View>(
    _ title: String, count: Int, open: Bool, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    VStack(spacing: 0) {
      Divider().padding(.vertical, 4)
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          if store.collapsed.contains(title) {
            store.collapsed.remove(title)
          } else {
            store.collapsed.insert(title)
          }
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: open ? "chevron.down" : "chevron.right").font(
            .system(size: 9, weight: .bold)
          ).frame(width: 10)
          Text(title).font(.system(size: 12, weight: .medium))
          Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
          trailing()
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 5).accessibilityLabel(
        "\(title), \(count)")
    }
  }
  var empty: some View {
    VStack(spacing: 9) {
      Image(
        systemName: store.search.isEmpty && store.filter == nil
          ? "checkmark.circle" : "magnifyingglass"
      )
      .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent)
      Text(store.search.isEmpty && store.filter == nil ? "No dev servers running" : "No matches")
        .font(.system(size: 15, weight: .medium))
      Text(
        store.search.isEmpty && store.filter == nil
          ? "Servers appear here the moment they start listening.\nApps and system ports are folded below."
          : "Try a project name, framework, port, branch or PID."
      ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.vertical, 24)
  }
  @ViewBuilder func row(_ w: Workload) -> some View {
    let selected = store.selected == w.id
    VStack(spacing: 0) {
      Row(store: store, w: w, acting: store.acting.contains(w.id))
      if selected { Detail(store: store, w: w) }
    }.background(selected ? accent.opacity(0.07) : Color.primary.opacity(0.03))
      .overlay(
        RoundedRectangle(cornerRadius: 11).stroke(
          selected ? accent.opacity(0.35) : .clear, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 11)).id(w.id)
      .contextMenu { WorkloadMenu(store: store, w: w) }
  }
}

struct RecentRow: View {
  @ObservedObject var store: Store
  var r: RecentServer
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: r.icon).font(.system(size: 15)).foregroundStyle(.secondary)
        .frame(width: 28, height: 30).background(Color.secondary.opacity(0.1)).clipShape(
          RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 3) {
        Text(r.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        Text(
          "\(r.kind)\(r.ports.isEmpty ? "" : " · " + r.ports.map { ":\($0)" }.joined(separator: " ")) · \(r.origin) · \(uptimeText(Date().timeIntervalSince(r.lastSeen))) ago"
        )
        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button("Launch") { store.launch(r) }.controlSize(.small).help(r.command)
      Button {
        store.forget(r)
      } label: {
        Image(systemName: "xmark")
      }.buttonStyle(.plain).foregroundStyle(.tertiary)
        .help("Forget").accessibilityLabel("Forget \(r.name)")
    }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 7)
      .background(Color.primary.opacity(0.02)).clipShape(RoundedRectangle(cornerRadius: 11))
      .contextMenu {
        Button("Launch in Terminal") { store.launch(r) }
        Button("Copy command") { store.copy(r.command) }
        Button("Copy directory") { store.copy(r.directory) }
        Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: r.directory)) }
        Divider()
        Button("Forget") { store.forget(r) }
      }
  }
}
