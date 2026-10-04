import AppKit
import Combine
import DevPortsCore
import ServiceManagement
import SwiftUI

enum PendingAction { case stop, restart }
enum WorkloadSort: String, CaseIterable {
  case name = "Name"
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
  @Published var notice: String?
  @Published var search = ""
  @Published var background = false
  @Published var showTree = false
  @Published var scan: Scan?
  @Published var error: String?
  @Published var busy = false
  @Published var selected: Identity?
  @Published var pending: PendingAction?
  @Published var confirmation: Workload?
  @Published var acting: Identity?
  @Published var messages: [Identity: String] = [:]
  var visible = false
  private var refreshPending = false
  private let monitor = ProcessMonitor()
  private var exits: [Identity: DispatchSourceProcess] = [:]
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
        if let id = selected, !next.workloads.contains(where: { $0.id == id }) {
          selected = nil
          pending = nil
        }
        messages = messages.filter { entry in next.workloads.contains { $0.id == entry.key } }
        observeExits(next.workloads)
      } catch { self.error = error.localizedDescription }
    }
  }
  private func observeExits(_ workloads: [Workload]) {
    // A transient helper exiting is not a workload exit; avoid refresh storms in worker trees.
    let live = Set(workloads.map(\.id))
    for id in Set(exits.keys).subtracting(live) { exits.removeValue(forKey: id)?.cancel() }
    for id in live where exits[id] == nil {
      let source = DispatchSource.makeProcessSource(
        identifier: id.pid, eventMask: .exit, queue: .main)
      source.setEventHandler { [weak self] in
        Task { @MainActor in self?.refresh() }
      }
      exits[id] = source
      source.resume()
    }
  }
  func act(_ w: Workload, restart: Bool) {
    guard acting == nil, error == nil else { return }
    if restart, let reason = w.restartReason {
      notice = reason
      return
    }
    acting = w.id
    pending = nil
    notice = nil
    Task {
      defer {
        acting = nil
        refresh()
      }
      do {
        try await Task.detached(priority: .userInitiated) { try Controller.stop(w) }.value
        if restart {
          try await launch(w)
          notice = "Launch command opened in Terminal for \(w.name)."
        } else {
          notice = "Stopped \(w.name)."
        }
      } catch {
        notice = error.localizedDescription
        messages[w.id] = error.localizedDescription
      }
    }
  }
  func launch(_ w: Workload) async throws {
    if let reason = w.restartReason { throw SafetyError(reason) }
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
}

struct Panel: View {
  @ObservedObject var store: Store
  private let accent = Color(red: 0.25, green: 0.63, blue: 0.95)
  var rows: [Workload] {
    (store.scan?.workloads ?? []).filter {
      store.search.isEmpty
        || "\($0.name) \($0.kind.name) \($0.ports) \($0.provenance)"
          .localizedCaseInsensitiveContains(store.search)
    }.sorted { a, b in
      switch store.sort {
      case .name: return (a.name, a.root.pid) < (b.name, b.root.pid)
      case .memory: return a.memory == b.memory ? a.root.pid < b.root.pid : a.memory > b.memory
      case .cpu: return a.cpu == b.cpu ? a.root.pid < b.root.pid : a.cpu > b.cpu
      case .uptime: return a.root.identity.start < b.root.identity.start
      }
    }
  }
  var servers: [Workload] { rows.filter { !$0.ports.isEmpty } }
  var workers: [Workload] { rows.filter { $0.ports.isEmpty } }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "point.3.connected.trianglepath.dotted").font(
          .system(size: 17, weight: .medium)
        ).foregroundStyle(accent)
        Text("DevPorts").font(.system(size: 14, weight: .semibold))
        Spacer()
        Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
        Text(store.busy ? "Scanning" : "Live").font(.system(size: 11)).foregroundStyle(.secondary)
        Button {
          store.refresh()
        } label: {
          Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
        }.buttonStyle(.borderless).help("Refresh · ⌘R").keyboardShortcut("r")
        Menu {
          Picker("Sort by", selection: $store.sort) {
            ForEach(WorkloadSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Divider()
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { SMAppService.mainApp.status == .enabled },
              set: { enabled in
                do {
                  if enabled {
                    try SMAppService.mainApp.register()
                  } else {
                    try SMAppService.mainApp.unregister()
                  }
                } catch { store.error = error.localizedDescription }
              }))
          Divider()
          Button("Quit DevPorts") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
      }.padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)
      HStack(spacing: 7) {
        Text("\(store.scan?.workloads.filter { !$0.ports.isEmpty }.count ?? 0) servers")
        Text("·")
        Text(memoryText(store.scan?.workloads.reduce(0) { $0 + $1.memory } ?? 0))
        Text("·")
        Text(String(format: "%.1f%% CPU", store.scan?.workloads.reduce(0) { $0 + $1.cpu } ?? 0))
        Spacer()
      }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).padding(
        .horizontal, 14
      ).padding(.bottom, 7)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
        TextField("Find a server, project, or port", text: $store.search).textFieldStyle(.plain)
          .font(.system(size: 12))
        if !store.search.isEmpty {
          Button {
            store.search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain)
        }
      }.padding(7).background(.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10).padding(.bottom, 9)
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
          .foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 10)
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
      ScrollView {
        VStack(spacing: 5) {
          HStack {
            Text("SERVERS").tracking(1.3)
            Spacer()
            Text("MEMORY").frame(width: 58, alignment: .trailing)
            Text("CPU").frame(width: 32, alignment: .trailing)
            Text("UPTIME").frame(width: 50, alignment: .trailing)
          }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(
            .horizontal, 14
          ).padding(.bottom, 5)
          ForEach(servers) { row($0) }
          if servers.isEmpty {
            VStack(spacing: 9) {
              Image(systemName: store.search.isEmpty ? "checkmark.circle" : "magnifyingglass").font(
                .system(size: 28, weight: .ultraLight)
              ).foregroundStyle(accent)
              Text(store.search.isEmpty ? "A quiet Mac." : "No matching servers").font(
                .system(size: 15, weight: .medium))
              Text(
                store.search.isEmpty
                  ? "Servers appear here when you start them.\nSystem services and app internals stay out of the way."
                  : "Try a project name, framework, or port."
              ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
          }
          Divider().padding(.vertical, 5)
          Button {
            withAnimation(.easeInOut(duration: 0.16)) { store.background.toggle() }
          } label: {
            HStack(spacing: 7) {
              Image(systemName: store.background ? "chevron.down" : "chevron.right").font(
                .system(size: 9, weight: .bold))
              Text("Background").font(.system(size: 12, weight: .medium))
              Text("\(workers.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(
                .secondary)
              Spacer()
              if workers.contains(where: { $0.orphan }) {
                Label("Orphaned", systemImage: "exclamationmark.circle.fill").font(
                  .system(size: 10)
                ).foregroundStyle(.orange)
              }
            }
          }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 6)
          if store.background || !store.search.isEmpty {
            ForEach(workers) { row($0) }
            if workers.isEmpty {
              Text("No meaningful background workloads").font(.system(size: 11))
                .foregroundStyle(.tertiary).padding(12)
            }
          }
        }.padding(.horizontal, 9).padding(.bottom, 8)
      }.defaultScrollAnchor(.top).scrollIndicators(.never).frame(maxHeight: .infinity)
      Divider()
      HStack {
        Text(
          store.scan.map { "\($0.count) processes checked · \(Int($0.duration*1000)) ms" }
            ?? "Reading your Mac…")
        Spacer()
        Text("Local only")
        Image(systemName: "lock.shield")
      }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(
        .vertical, 8)
    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
      Color(nsColor: .windowBackgroundColor))
  }
  @ViewBuilder func row(_ w: Workload) -> some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          store.selected = store.selected == w.id ? nil : w.id
          store.pending = nil
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: w.kind.icon).font(.system(size: 17)).foregroundStyle(
            w.orphan ? .orange : accent
          ).frame(width: 26, height: 30).background(accent.opacity(0.09)).clipShape(
            RoundedRectangle(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 4) {
            Text(w.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 5) {
              Text(w.kind.name).foregroundStyle(.secondary)
              if !w.ports.isEmpty {
                Text(w.ports.map { ":\($0)" }.joined(separator: " ")).foregroundStyle(accent)
              }
              if w.orphan {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
              }
            }.font(.system(size: 10)).lineLimit(1)
          }
          Spacer(minLength: 4)
          Text(memoryText(w.memory)).foregroundStyle(w.memory >= 2_000_000_000 ? .orange : .primary)
            .frame(width: 58, alignment: .trailing)
          Text(String(format: "%.0f%%", w.cpu)).frame(width: 32, alignment: .trailing)
          Text(uptimeText(w.uptime)).foregroundStyle(.secondary).frame(
            width: 50, alignment: .trailing)
        }.font(.system(size: 11, design: .monospaced)).monospacedDigit().padding(.horizontal, 12)
          .padding(.vertical, 8).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if store.selected == w.id { detail(w) }
    }.background(store.selected == w.id ? accent.opacity(0.065) : Color.primary.opacity(0.025))
      .clipShape(RoundedRectangle(cornerRadius: 11))
  }
  @ViewBuilder func detail(_ w: Workload) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Divider()
      HStack {
        Label(
          w.provenance, systemImage: w.orphan ? "exclamationmark.circle" : "arrow.turn.down.right")
        Spacer()
        Text("PID \(w.root.pid) · \(w.members.count) process\(w.members.count==1 ? "":"es")")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Text(w.root.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        .textSelection(.enabled).lineLimit(2)
      ScrollView(.horizontal) {
        Text(w.root.command).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          .padding(9)
      }.background(.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
      DisclosureGroup("Process tree", isExpanded: $store.showTree) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(w.members, id: \.identity) { p in
            Text(
              "\(p.pid) ← \(p.parent)  \(p.args.dropFirst().first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? p.base)"
            )
            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).help(p.command)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        if w.kind.web, !w.ports.isEmpty {
          Menu("Open") {
            ForEach(w.ports, id: \.self) { port in
              Button(":\(port)") {
                NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
              }
            }
          }.frame(width: 65)
        }
        Menu("Project") {
          Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: w.root.cwd)) }
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root.cwd)])
          }
          Divider()
          ForEach(["Visual Studio Code", "Zed"], id: \.self) { name in
            if FileManager.default.fileExists(atPath: "/Applications/\(name).app") {
              Button("Open in \(name)") {
                NSWorkspace.shared.open(
                  [URL(fileURLWithPath: w.root.cwd)],
                  withApplicationAt: URL(fileURLWithPath: "/Applications/\(name).app"),
                  configuration: NSWorkspace.OpenConfiguration())
              }
            }
          }
          Button("Open in Terminal") {
            NSWorkspace.shared.open(
              [URL(fileURLWithPath: w.root.cwd)],
              withApplicationAt: URL(
                fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
              configuration: NSWorkspace.OpenConfiguration())
          }
        }.frame(width: 80).disabled(w.root.cwd.isEmpty)
        Menu("Inspect") {
          Button("Copy process tree") {
            copy(
              w.members.map { "PID \($0.pid) ← \($0.parent)\n\($0.command)" }.joined(
                separator: "\n\n"))
          }
          Button("Copy command") { copy(w.root.command) }
          Button("Copy directory") { copy(w.root.cwd) }
          Button("Copy ports") { copy(w.ports.map(String.init).joined(separator: ", ")) }
        }.frame(width: 80)
        Spacer()
        if store.acting == w.id { ProgressView().controlSize(.small) }
        Button("Restart") {
          store.confirmation = w
          store.pending = .restart
        }.disabled(
          w.restartReason != nil || store.acting != nil || store.error != nil
        ).help(w.restartReason ?? "Review command before restarting")
        Button("Stop") {
          store.confirmation = w
          store.pending = .stop
        }.foregroundStyle(.red).disabled(
          w.refusal != nil || store.acting != nil || store.error != nil
        ).help(w.refusal ?? "Stop this workload")
      }.controlSize(.small)
      if let reason = w.refusal {
        Label(reason, systemImage: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if let message = store.messages[w.id] {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange)
      }
      if let pending = store.pending, let confirmed = store.confirmation, confirmed.id == w.id {
        VStack(alignment: .leading, spacing: 9) {
          Text(pending == .stop ? "Stop \(w.name)?" : "Restart \(w.name) in Terminal?").font(
            .system(size: 12, weight: .semibold))
          Text(
            pending == .stop
              ? (w.usesMinecraftController
                ? "Asks your Minecraft controller to stop the server, save its world, and finish its backup. No force kill."
                : "Gracefully terminates these \(confirmed.members.count) processes after checking their identities and tree again.")
              : "Runs the command above in its original directory using a fresh Terminal environment. Inherited variables and input cannot be recovered."
          ).font(.system(size: 11)).foregroundStyle(.secondary)
          HStack {
            Text(confirmed.members.map { "\($0.pid)" }.joined(separator: " · ")).font(
              .system(size: 10, design: .monospaced)
            ).foregroundStyle(.tertiary).lineLimit(2)
            Spacer()
            Button("Cancel") { store.pending = nil }
            Button(pending == .stop ? "Stop workload" : "Restart") {
              store.act(confirmed, restart: pending == .restart)
            }.tint(pending == .stop ? .red : accent).buttonStyle(.borderedProminent)
          }
        }.padding(11).background(.primary.opacity(0.04)).clipShape(
          RoundedRectangle(cornerRadius: 8))
      }
    }.padding(.horizontal, 9).padding(.bottom, 8)
  }
  func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
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
    let host = NSHostingView(rootView: Panel(store: store))
    host.sizingOptions = []
    host.wantsLayer = true
    host.layer?.cornerRadius = 14
    host.layer?.masksToBounds = true
    panel.contentView = host
    observation = store.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { self?.updatePanel() }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
      [weak self] event in
      if event.type == .keyDown && event.keyCode == 53 {
        self?.close()
        return nil
      }
      return event
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication, app.processIdentifier != getpid()
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
    let count = store.scan?.workloads.filter { !$0.ports.isEmpty }.count ?? 0
    let title = count > 0 ? " \(count)" : ""
    if item.button?.title != title { item.button?.title = title }
    guard store.visible, let button = item.button, let window = button.window,
      let screen = window.screen
    else { return }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let servers = store.scan?.workloads.filter { !$0.ports.isEmpty }.count ?? 0
    let background =
      store.background ? (store.scan?.workloads.filter { $0.ports.isEmpty }.count ?? 0) : 0
    let desired =
      186.0 + Double(max(servers, 1) + background) * 54 + (store.selected == nil ? 0 : 240)
      + (store.pending == nil ? 0 : 110) + (store.showTree ? 100 : 0)
    let frame = PanelPlacement.frame(
      anchor: anchor, screen: screen.visibleFrame, desiredHeight: desired)
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
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: store.visible ? 3 : 30, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.store.refresh() }
    }
    timer?.tolerance = store.visible ? 1 : 5
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard store.acting == nil else {
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
    store.pending = nil
    store.confirmation = nil
  }
}
