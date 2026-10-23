import AppKit
import Combine
import DevPortsCore
import ServiceManagement
import SwiftUI

enum WorkloadSort: String, CaseIterable {
  case name = "Name"
  case port = "Port"
  case memory = "Memory"
  case cpu = "CPU"
  case uptime = "Uptime"
}

@MainActor final class Store: ObservableObject {
  @Published var sort =
    WorkloadSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "Name") ?? .name
  {
    didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
  }
  @Published var collapsed: Set<String> = Set(
    UserDefaults.standard.stringArray(forKey: "collapsed") ?? ["Apps", "System & tools"])
  {
    didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
  }
  @Published var notice: String?
  @Published var search = ""
  @Published var scan: Scan?
  @Published var error: String?
  @Published var busy = false
  @Published var selected: Identity?
  @Published var showTree = false
  /// Row whose hover button is waiting for its second click, and the signal it will send.
  @Published var armed: (id: Identity, signal: Signal)?
  @Published var acting: Set<Identity> = []
  @Published var messages: [Identity: String] = [:]
  /// Workloads that survived a Stop and now offer Force Quit prominently.
  @Published var lingering: Set<Identity> = []
  var visible = false
  var isQuiet: Bool { scan?.workloads.allSatisfy { $0.section == .system } == true && error == nil }
  var compact: Bool { isQuiet && notice == nil && acting.isEmpty }
  private var refreshPending = false
  private var armTimer: Task<Void, Never>?
  private let monitor = ProcessMonitor()
  private var exits: [Identity: DispatchSourceProcess] = [:]

  var rows: [Workload] {
    (scan?.workloads ?? []).filter {
      search.isEmpty
        || "\($0.name) \($0.kind.name) \($0.ports.map { ":\($0)" }.joined(separator: " ")) \($0.provenance) \($0.root.pid)"
          .localizedCaseInsensitiveContains(search)
    }.sorted { a, b in
      switch sort {
      case .name: return (a.name.lowercased(), a.root.pid) < (b.name.lowercased(), b.root.pid)
      case .port: return (a.ports.first ?? .max, a.root.pid) < (b.ports.first ?? .max, b.root.pid)
      case .memory: return a.memory == b.memory ? a.root.pid < b.root.pid : a.memory > b.memory
      case .cpu: return a.cpu == b.cpu ? a.root.pid < b.root.pid : a.cpu > b.cpu
      case .uptime: return a.root.identity.start < b.root.identity.start
      }
    }
  }
  func lane(_ section: Lane) -> [Workload] { rows.filter { $0.section == section } }
  var servers: [Workload] { lane(.servers) }
  /// Rows in display order, for keyboard navigation.
  var visibleRows: [Workload] {
    Lane.allCases.flatMap { section in
      section == .servers || !collapsed.contains(section.rawValue) || !search.isEmpty
        ? lane(section) : []
    }
  }
  func workload(_ id: Identity) -> Workload? { scan?.workloads.first { $0.id == id } }

  func refresh() {
    guard !busy else {
      refreshPending = true
      return
    }
    busy = true
    Task {
      defer {
        busy = false
        if refreshPending {
          refreshPending = false
          refresh()
        }
      }
      do {
        let next = try await monitor.scan()
        scan = next
        error = nil
        let ids = Set(next.workloads.map(\.id))
        if let id = selected, !ids.contains(id) { selected = nil }
        if let a = armed, !ids.contains(a.id) { armed = nil }
        messages = messages.filter { ids.contains($0.key) }
        lingering = lingering.intersection(ids)
        observeExits(next.workloads)
      } catch { self.error = error.localizedDescription }
    }
  }
  private func observeExits(_ workloads: [Workload]) {
    let live = Set(workloads.map(\.id))
    for id in Set(exits.keys).subtracting(live) { exits.removeValue(forKey: id)?.cancel() }
    for id in live where exits[id] == nil {
      let source = DispatchSource.makeProcessSource(
        identifier: id.pid, eventMask: .exit, queue: .main)
      source.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
      exits[id] = source
      source.resume()
    }
  }

  // MARK: Actions

  func arm(_ w: Workload, _ signal: Signal) {
    if let a = armed, a.id == w.id, a.signal == signal {
      armed = nil
      act(w, signal)
      return
    }
    armed = (w.id, signal)
    armTimer?.cancel()
    armTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.armed = nil
    }
  }
  func act(_ w: Workload, _ signal: Signal) {
    guard !acting.contains(w.id) else { return }
    if w.section == .apps, let app = NSRunningApplication(processIdentifier: w.root.pid) {
      let ok = signal == .kill ? app.forceTerminate() : app.terminate()
      notice =
        ok
        ? "\(signal == .kill ? "Force quit" : "Asked to quit") \(w.name)."
        : "\(w.name) refused to quit."
      messages[w.id] = nil
      Task {
        try? await Task.sleep(for: .seconds(1))
        refresh()
      }
      return
    }
    acting.insert(w.id)
    messages[w.id] = nil
    Task {
      defer {
        acting.remove(w.id)
        refresh()
      }
      do {
        let outcome = try await Task.detached(priority: .userInitiated) {
          try Controller.stop(w, signal)
        }.value
        if outcome.done {
          lingering.remove(w.id)
          notice =
            "\(signal == .kill ? "Force quit" : "Stopped") \(w.name) · \(outcome.signalled.count) process\(outcome.signalled.count == 1 ? "" : "es")."
        } else {
          lingering.insert(w.id)
          let pids = outcome.remaining.map { "\($0.base) \($0.pid)" }.joined(separator: ", ")
          messages[w.id] =
            signal == .kill
            ? "Still present after SIGKILL: \(pids). It may be a zombie waiting for its parent."
            : "Still running after \(Int(signal.grace)) s: \(pids). Force Quit ends it immediately."
          notice = nil
        }
      } catch {
        messages[w.id] = error.localizedDescription
      }
    }
  }
  func act(_ p: Proc, in w: Workload, _ signal: Signal) {
    guard !acting.contains(w.id) else { return }
    acting.insert(w.id)
    Task {
      defer {
        acting.remove(w.id)
        refresh()
      }
      do {
        let outcome = try await Task.detached(priority: .userInitiated) {
          try Controller.stop(p, in: w, signal)
        }.value
        messages[w.id] =
          outcome.done
          ? "\(signal.rawValue) sent to \(p.base) \(p.pid); it exited."
          : "\(p.base) \(p.pid) is still running after \(signal.rawValue)."
      } catch { messages[w.id] = error.localizedDescription }
    }
  }
  func stopAll(_ signal: Signal) {
    let targets = servers.filter { $0.blocked == nil && !acting.contains($0.id) }
    guard !targets.isEmpty else {
      notice = "No servers to stop."
      return
    }
    acting.formUnion(targets.map(\.id))
    Task {
      defer {
        acting.subtract(targets.map(\.id))
        refresh()
      }
      let results = await Task.detached(priority: .userInitiated) {
        Controller.stopAll(targets, signal)
      }.value
      var stopped = 0
      for (id, result) in results {
        switch result {
        case .success(let outcome):
          if outcome.done {
            stopped += 1
            lingering.remove(id)
          } else {
            lingering.insert(id)
            messages[id] =
              "Still running: " + outcome.remaining.map { "\($0.pid)" }.joined(separator: ", ")
          }
        case .failure(let error): messages[id] = error.message
        }
      }
      notice = "Stopped \(stopped) of \(targets.count) servers."
    }
  }
  func unload(_ w: Workload) {
    guard let label = w.launchdLabel else { return }
    acting.insert(w.id)
    Task {
      defer {
        acting.remove(w.id)
        refresh()
      }
      do {
        if let service = w.brewService {
          try await Task.detached { try Controller.brewStop(service) }.value
          notice = "brew services stopped \(service)."
        } else {
          try await Task.detached { try Controller.unloadLaunchAgent(label) }.value
          notice = "Unloaded \(label) from launchd."
        }
      } catch { messages[w.id] = error.localizedDescription }
    }
  }
  func restart(_ w: Workload) {
    if let reason = w.restartReason {
      messages[w.id] = reason
      return
    }
    acting.insert(w.id)
    Task {
      defer {
        acting.remove(w.id)
        refresh()
      }
      do {
        let outcome = try await Task.detached(priority: .userInitiated) {
          try Controller.stop(w, .terminate)
        }.value
        guard outcome.done else {
          lingering.insert(w.id)
          messages[w.id] = "Not restarted: the old process is still running. Force Quit it first."
          return
        }
        try await launch(w)
        notice = "Launch command opened in Terminal for \(w.name)."
      } catch { messages[w.id] = error.localizedDescription }
    }
  }
  func launch(_ w: Workload) async throws {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/DevPorts")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent("Restart-\(UUID().uuidString).command")
    let command = ([w.root.path] + Array(w.root.args.dropFirst())).map(shellQuote).joined(
      separator: " ")
    let script =
      "#!/bin/zsh\n/bin/rm -- \"$0\"\ncd -- \(shellQuote(w.root.cwd)) || exit 1\nexec \(command)\n"
    try script.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    _ = try await NSWorkspace.shared.open(
      [file],
      withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
      configuration: NSWorkspace.OpenConfiguration())
  }
  func open(port: Int) { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
  func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    notice = "Copied."
  }

  // MARK: Keyboard

  /// Returns true when the key was consumed.
  func handle(_ event: NSEvent) -> Bool {
    // Arrow keys carry the function and numeric-pad flags; only the real modifiers matter here.
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let rows = visibleRows
    switch (event.keyCode, flags) {
    case (125, []):  // down
      move(1, in: rows)
    case (126, []):  // up
      move(-1, in: rows)
    case (36, []), (49, []):  // return, space
      guard let id = selected, event.keyCode == 36 || !searchFocused else { return false }
      showTree = showTree && selected == id
      return true
    case (51, [.command]):  // ⌘⌫
      guard let w = current, w.blocked == nil else { return false }
      act(w, .terminate)
    case (51, [.command, .shift]):
      guard let w = current, w.blocked == nil else { return false }
      act(w, .kill)
    case (31, [.command]):  // ⌘O
      guard let w = current, let port = w.ports.first else { return false }
      open(port: port)
    case (15, [.command]):  // ⌘R
      refresh()
    default: return false
    }
    return true
  }
  var searchFocused = false
  var current: Workload? { selected.flatMap(workload) }
  private func move(_ delta: Int, in rows: [Workload]) {
    guard !rows.isEmpty else { return }
    var index: Int = delta > 0 ? 0 : rows.count - 1
    if let current = rows.firstIndex(where: { $0.id == selected }) { index = current + delta }
    index = max(0, min(rows.count - 1, index))
    selected = rows[index].id
  }
}

let accent = Color(red: 0.25, green: 0.63, blue: 0.95)

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

struct Panel: View {
  @ObservedObject var store: Store
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      header
      if store.compact {
        HStack(spacing: 9) {
          Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text("All quiet").font(.system(size: 13, weight: .medium))
            Text("No servers or background workloads.").font(.system(size: 11)).foregroundStyle(
              .secondary)
          }
          Spacer()
        }.padding(.horizontal, 14).padding(.top, 3)
        Spacer(minLength: 10)
      } else {
        stats
        searchField
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
          }.padding(.horizontal, 14).padding(.bottom, 7)
        }
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 4) {
              ForEach(Lane.allCases, id: \.self) { section in sectionView(section) }
            }.padding(.horizontal, 9).padding(.bottom, 8)
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
      Text("DevPorts").font(.system(size: 14, weight: .semibold))
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
        Button("Stop all servers") { store.stopAll(.terminate) }.disabled(
          store.servers.allSatisfy { $0.blocked != nil })
        Button("Force quit all servers") { store.stopAll(.kill) }.disabled(
          store.servers.allSatisfy { $0.blocked != nil })
        Divider()
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
        Button("Quit DevPorts") { NSApp.terminate(nil) }.keyboardShortcut("q")
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
    }.padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)
  }
  var stats: some View {
    let servers = store.scan?.workloads.filter { $0.section == .servers } ?? []
    let exposed = store.scan?.workloads.filter { $0.exposed && $0.section != .system }.count ?? 0
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
      TextField("Find a server, project, port or PID", text: $store.search).textFieldStyle(.plain)
        .font(.system(size: 12)).focused($searchFocused).accessibilityLabel("Search")
      if !store.search.isEmpty {
        Button {
          store.search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }.buttonStyle(.plain).accessibilityLabel("Clear search")
      } else {
        Text("⌘F").font(.system(size: 9, weight: .medium)).foregroundStyle(.quaternary)
      }
    }.padding(7).background(.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 9))
      .padding(.horizontal, 10).padding(.bottom, 9)
  }
  var footer: some View {
    HStack {
      Text(
        store.scan.map {
          "\($0.count) processes · \(String(format: "%.1f", $0.duration * 1000)) ms"
        } ?? "Reading your Mac…")
      Spacer()
      Text("⌘⌫ stop · ⌘⇧⌫ force · ⌘O open").foregroundStyle(.quaternary)
      Image(systemName: "lock.shield")
    }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(
      .vertical, 8)
  }

  @ViewBuilder func sectionView(_ section: Lane) -> some View {
    let rows = store.lane(section)
    let open =
      section == .servers || !store.collapsed.contains(section.rawValue) || !store.search.isEmpty
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
      Divider().padding(.vertical, 4)
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          if store.collapsed.contains(section.rawValue) {
            store.collapsed.remove(section.rawValue)
          } else {
            store.collapsed.insert(section.rawValue)
          }
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: open ? "chevron.down" : "chevron.right").font(
            .system(size: 9, weight: .bold)
          ).frame(width: 10)
          Text(section.rawValue).font(.system(size: 12, weight: .medium))
          Text("\(rows.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(
            .secondary)
          Spacer()
          if section == .background, rows.contains(where: { $0.orphan }) {
            Label("Orphaned", systemImage: "exclamationmark.circle.fill").font(.system(size: 10))
              .foregroundStyle(.orange)
          }
          if section == .system {
            Text("read only").font(.system(size: 10)).foregroundStyle(.tertiary)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 5)
        .accessibilityLabel("\(section.rawValue), \(rows.count)")
      if open {
        ForEach(rows) { row($0) }
        if rows.isEmpty {
          Text("No background workloads").font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(10)
        }
      }
    }
  }
  var empty: some View {
    VStack(spacing: 9) {
      Image(systemName: store.search.isEmpty ? "checkmark.circle" : "magnifyingglass").font(
        .system(size: 28, weight: .ultraLight)
      ).foregroundStyle(accent)
      Text(store.search.isEmpty ? "No dev servers running" : "No matches").font(
        .system(size: 15, weight: .medium))
      Text(
        store.search.isEmpty
          ? "Servers appear here the moment they start listening.\nApps and system ports are folded below."
          : "Try a project name, framework, port or PID."
      ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.vertical, 24)
  }

  @ViewBuilder func row(_ w: Workload) -> some View {
    let selected = store.selected == w.id
    let acting = store.acting.contains(w.id)
    VStack(spacing: 0) {
      Row(store: store, w: w, acting: acting)
      if selected { detail(w) }
    }.background(selected ? accent.opacity(0.07) : Color.primary.opacity(0.03))
      .overlay(
        RoundedRectangle(cornerRadius: 11).stroke(
          selected ? accent.opacity(0.35) : .clear, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 11)).id(w.id)
      .contextMenu { menu(w) }
  }
  @ViewBuilder func menu(_ w: Workload) -> some View {
    if w.blocked == nil {
      Button(w.section == .apps ? "Quit \(w.name)" : "Stop") { store.act(w, .terminate) }
      if w.section != .apps { Button("Interrupt (Ctrl-C)") { store.act(w, .interrupt) } }
      Button("Force Quit") { store.act(w, .kill) }
      if w.launchdLabel != nil {
        Button(w.brewService.map { "brew services stop \($0)" } ?? "Unload from launchd") {
          store.unload(w)
        }
      }
      if w.restartReason == nil { Button("Restart in Terminal") { store.restart(w) } }
      Divider()
    }
    ForEach(w.ports, id: \.self) { port in
      Button("Open localhost:\(port)") { store.open(port: port) }
    }
    if !w.root.cwd.isEmpty {
      Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.root.cwd)) }
      Button("Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root.cwd)])
      }
      ForEach(editors, id: \.self) { name in
        Button("Open in \(name)") { openIn(name, w.root.cwd) }
      }
    }
    Divider()
    if !w.root.command.isEmpty { Button("Copy command") { store.copy(w.root.command) } }
    if !w.root.cwd.isEmpty { Button("Copy directory") { store.copy(w.root.cwd) } }
    if !w.ports.isEmpty {
      Button("Copy ports") { store.copy(w.ports.map(String.init).joined(separator: ", ")) }
      Button("Copy curl") { store.copy("curl -i http://localhost:\(w.ports[0])/") }
    }
    Button("Copy PID") { store.copy("\(w.root.pid)") }
    Button("Copy kill command") {
      store.copy("kill \(w.members.map { "\($0.pid)" }.joined(separator: " "))")
    }
  }
  var editors: [String] {
    ["Visual Studio Code", "Cursor", "Zed", "Xcode", "Ghostty", "iTerm", "Warp", "Terminal"].filter
    {
      FileManager.default.fileExists(atPath: appPath($0))
    }
  }
  func appPath(_ name: String) -> String {
    name == "Terminal" ? "/System/Applications/Utilities/Terminal.app" : "/Applications/\(name).app"
  }
  func openIn(_ name: String, _ folder: String) {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: folder)], withApplicationAt: URL(fileURLWithPath: appPath(name)),
      configuration: NSWorkspace.OpenConfiguration())
  }

  @ViewBuilder func detail(_ w: Workload) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      HStack {
        Label(
          w.provenance, systemImage: w.orphan ? "exclamationmark.circle" : "arrow.turn.down.right")
        Spacer()
        Text("PID \(w.root.pid) · \(w.members.count) process\(w.members.count == 1 ? "" : "es")")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      if !w.root.cwd.isEmpty {
        Text(w.root.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .textSelection(.enabled).lineLimit(2)
      }
      if !w.root.command.isEmpty {
        ScrollView(.horizontal) {
          Text(w.root.command).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            .padding(9)
        }.background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
      }
      ForEach(w.listeners, id: \.self) { l in
        HStack(spacing: 6) {
          Image(systemName: l.wildcard ? "antenna.radiowaves.left.and.right" : "lock")
            .foregroundStyle(l.wildcard ? .orange : .secondary)
          Text("\(l.address):\(l.port)").font(.system(size: 10, design: .monospaced))
          Text(l.wildcard ? "reachable from your network" : "local only").foregroundStyle(
            .secondary)
          if l.pid != w.root.pid { Text("· PID \(l.pid)").foregroundStyle(.tertiary) }
        }.font(.system(size: 10))
      }
      ForEach(w.cautions, id: \.self) { caution in
        Label(caution, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(
          .secondary)
      }
      if let blocked = w.blocked {
        Label(blocked, systemImage: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if !w.members.isEmpty {
        DisclosureGroup("Process tree", isExpanded: $store.showTree) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(w.members, id: \.identity) { p in
              HStack(spacing: 6) {
                Text("\(p.pid)").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
                Text(
                  p.args.dropFirst().first.map { URL(fileURLWithPath: $0).lastPathComponent }.map {
                    "\(p.base) \($0)"
                  } ?? p.base
                ).lineLimit(1)
                if p.suspended { Text("suspended").foregroundStyle(.orange) }
                Spacer()
                Text(memoryText(p.memory)).foregroundStyle(.tertiary)
                Menu {
                  Button("Stop \(p.pid)") { store.act(p, in: w, .terminate) }
                  Button("Force Quit \(p.pid)") { store.act(p, in: w, .kill) }
                  Button("Copy command") { store.copy(p.command) }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
              }.font(.system(size: 10, design: .monospaced)).help(p.command)
            }
            ForEach(w.excluded, id: \.identity) { p in
              HStack(spacing: 6) {
                Text("\(p.pid)").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
                Text(p.base).lineLimit(1)
                Text("left running · \(Policy.protection(p) ?? "protected")").foregroundStyle(
                  .tertiary)
                Spacer()
              }.font(.system(size: 10, design: .monospaced))
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if !w.ports.isEmpty, w.kind.web {
          Menu("Open") {
            ForEach(w.ports, id: \.self) { port in Button(":\(port)") { store.open(port: port) } }
          }.frame(width: 65)
        }
        if !w.root.cwd.isEmpty {
          Menu("Project") {
            Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.root.cwd)) }
            Button("Reveal in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root.cwd)])
            }
            Divider()
            ForEach(editors, id: \.self) { name in
              Button("Open in \(name)") { openIn(name, w.root.cwd) }
            }
          }.frame(width: 80)
        }
        Spacer()
        if store.acting.contains(w.id) { ProgressView().controlSize(.small) }
        if w.blocked == nil {
          if w.launchdLabel != nil {
            Button(w.brewService != nil ? "brew stop" : "Unload") { store.unload(w) }.help(
              w.cautions.first ?? "")
          }
          if w.section != .apps {
            Button("Restart") { store.restart(w) }.disabled(
              w.restartReason != nil || store.acting.contains(w.id)
            )
            .help(w.restartReason ?? "Stop, then rerun the command in Terminal")
          }
          Button(w.section == .apps ? "Quit" : "Stop") { store.act(w, .terminate) }
            .disabled(store.acting.contains(w.id)).help(
              "SIGTERM to \(w.members.count) processes · ⌘⌫")
          if store.lingering.contains(w.id) {
            Button("Force Quit") { store.act(w, .kill) }.tint(.red).buttonStyle(.borderedProminent)
              .disabled(store.acting.contains(w.id)).help("SIGKILL · ⌘⇧⌫")
          } else {
            Button("Force Quit") { store.act(w, .kill) }
              .disabled(store.acting.contains(w.id)).help("SIGKILL · ⌘⇧⌫")
          }
        }
      }.controlSize(.small)
      if let message = store.messages[w.id] {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
      }
    }.padding(.horizontal, 11).padding(.bottom, 9)
  }
}

struct Row: View {
  @ObservedObject var store: Store
  var w: Workload
  var acting: Bool
  @State private var hovering = false
  var armed: Signal? { store.armed.flatMap { $0.id == w.id ? $0.signal : nil } }
  var body: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          store.selected = store.selected == w.id ? nil : w.id
          store.armed = nil
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: w.kind.icon).font(.system(size: 15)).foregroundStyle(
            w.orphan ? .orange : w.section == .system ? .secondary : accent
          )
          .frame(width: 28, height: 30).background(
            (w.section == .system ? Color.secondary : accent).opacity(0.1)
          ).clipShape(RoundedRectangle(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
              Text(w.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
              if w.exposed {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 9))
                  .foregroundStyle(.orange).help("Listening on all interfaces")
              }
              if w.suspended { Text("suspended").font(.system(size: 9)).foregroundStyle(.orange) }
              if w.orphan {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
                  .foregroundStyle(.orange)
              }
            }
            HStack(spacing: 5) {
              Text(w.kind.name).foregroundStyle(.secondary).lineLimit(1)
              if w.launchdLabel != nil {
                Image(systemName: "gearshape").foregroundStyle(.tertiary).help(w.launchdLabel ?? "")
              }
            }.font(.system(size: 10))
          }
          Spacer(minLength: 4)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(
          "\(w.name), \(w.kind.name)\(w.ports.map { ", port \($0)" }.joined())")

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
            .help(w.kind.web ? "Open http://localhost:\(port)" : "Copy \(port)")
            .accessibilityLabel("Port \(port)")
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
      } else {
        if store.lingering.contains(w.id) {
          Button("Force Quit") { store.arm(w, .kill) }.buttonStyle(.borderedProminent).tint(.red)
            .controlSize(.small)
        } else {
          Button {
            store.arm(w, NSEvent.modifierFlags.contains(.option) ? .kill : .terminate)
          } label: {
            Label(w.section == .apps ? "Quit" : "Stop", systemImage: "xmark.circle.fill")
          }.buttonStyle(.bordered).controlSize(.small).help("Stop · ⌥ for Force Quit")
            .accessibilityLabel("Stop \(w.name)")
        }
      }
    }.frame(width: 190, alignment: .trailing)
  }
}

final class MenuPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = Store()
  let panel = MenuPanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
  var item: NSStatusItem!
  var timer: Timer?
  var refreshInterval: TimeInterval?
  var observation: AnyCancellable?
  var outsideMonitor: Any?
  var keyMonitor: Any?
  var activationObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ note: Notification) {
    NSApp.setActivationPolicy(.accessory)
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(
      systemSymbolName: "point.3.connected.trianglepath.dotted",
      accessibilityDescription: "DevPorts")
    item.button?.target = self
    item.button?.action = #selector(toggle)
    item.button?.toolTip = "DevPorts — servers on your Mac"
    panel.title = "DevPorts"
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = 14
    material.layer?.masksToBounds = true
    let host = NSHostingView(rootView: Panel(store: store))
    host.sizingOptions = []
    host.translatesAutoresizingMaskIntoConstraints = false
    material.addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
      host.topAnchor.constraint(equalTo: material.topAnchor),
      host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
    ])
    panel.contentView = material
    observation = store.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { self?.updatePanel() }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, panel.isVisible else { return event }
      if event.keyCode == 53 {
        close()
        return nil
      }
      if event.keyCode == 3, event.modifierFlags.contains(.command) {  // ⌘F
        panel.makeFirstResponder(panel.contentView?.firstTextField)
        return nil
      }
      return store.handle(event) ? nil : event
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        app.processIdentifier != getpid()
      else { return }
      Task { @MainActor in self?.close() }
    }
    store.refresh()
    scheduleRefresh()
    if CommandLine.arguments.contains("--enable-login") {
      do { try SMAppService.mainApp.register() } catch {
        store.error = "Launch at login: \(error.localizedDescription)"
      }
    }
    if CommandLine.arguments.contains("--show") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.toggle() }
    }
  }
  func updatePanel() {
    scheduleRefresh()
    let servers = store.scan?.workloads.filter { $0.section == .servers } ?? []
    let title = servers.isEmpty ? "" : " \(servers.count)"
    if item.button?.title != title { item.button?.title = title }
    if let button = item.button {
      button.contentTintColor = servers.contains { $0.exposed } ? .systemOrange : nil
    }
    guard store.visible, let button = item.button, let window = button.window,
      let screen = window.screen
    else { return }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let rows: Double = Double(max(store.visibleRows.count, 1))
    let sections: Double = Double(
      Lane.allCases.filter { $0 != .servers && (!store.lane($0).isEmpty || $0 == .background) }
        .count)
    var detail: Double = 0
    if let w = store.current {
      detail = 220 + Double(w.listeners.count + w.cautions.count) * 16
      if store.showTree { detail += Double(w.members.count + w.excluded.count) * 17 + 20 }
    }
    var desired: Double = 196 + rows * 50 + sections * 36 + detail
    if store.notice != nil { desired += 24 }
    if store.error != nil { desired += 24 }
    let frame = PanelPlacement.frame(
      anchor: anchor, screen: screen.visibleFrame, desiredHeight: store.compact ? 106 : desired,
      desiredWidth: store.compact ? 320 : 500)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }
  @objc func toggle() {
    if panel.isVisible {
      close()
    } else {
      store.visible = true
      scheduleRefresh()
      store.refresh()
      updatePanel()
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
      observeOutsideClicks()
    }
  }
  func scheduleRefresh() {
    let interval: TimeInterval =
      store.visible ? (store.isQuiet ? 4 : 2) : (store.isQuiet ? 120 : 30)
    guard refreshInterval != interval else { return }
    refreshInterval = interval
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.store.refresh() }
    }
    timer?.tolerance = store.visible ? 0.5 : (store.isQuiet ? 20 : 5)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard store.acting.isEmpty else {
      store.notice = "A shutdown is still finishing. Quit again once it completes."
      return .terminateCancel
    }
    return .terminateNow
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !panel.isVisible { toggle() }
    return false
  }
  func observeOutsideClicks() {
    guard outsideMonitor == nil else { return }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])
    { [weak self] _ in
      Task { @MainActor in self?.close() }
    }
  }
  func close() {
    guard store.visible || panel.isVisible else { return }
    if let monitor = outsideMonitor {
      NSEvent.removeMonitor(monitor)
      outsideMonitor = nil
    }
    panel.orderOut(nil)
    store.visible = false
    scheduleRefresh()
    store.armed = nil
  }
}

extension NSView {
  var firstTextField: NSView? {
    if self is NSTextField { return self }
    for view in subviews { if let found = view.firstTextField { return found } }
    return nil
  }
}
