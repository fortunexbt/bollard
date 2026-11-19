import AppKit
import BollardCore
import Foundation
import ServiceManagement
import SwiftUI

enum WorkloadSort: String, CaseIterable {
  case name = "Name"
  case port = "Port"
  case memory = "Memory"
  case cpu = "CPU"
  case uptime = "Uptime"
}

@MainActor @Observable final class Store {
  @ObservationIgnored private let defaults = UserDefaults.standard
  var sort: WorkloadSort {
    didSet { defaults.set(sort.rawValue, forKey: "sort") }
  }
  var collapsed: Set<String> {
    didSet { defaults.set(Array(collapsed), forKey: "collapsed.4") }
  }
  var notify: Bool {
    didSet {
      defaults.set(notify, forKey: "notify")
      if notify { notifier.prepare() }
    }
  }
  var hotkeyEnabled: Bool {
    didSet { defaults.set(hotkeyEnabled, forKey: "hotkey") }
  }
  /// Mirrors the login item. Asking macOS is a blocking round trip to a system service, so it is
  /// read when the panel opens and never while drawing.
  var launchAtLogin = false {
    didSet {
      guard launchAtLogin != oldValue, launchAtLogin != (SMAppService.mainApp.status == .enabled)
      else { return }
      do {
        launchAtLogin
          ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
      } catch {
        self.error = "Launch at login: \(error.localizedDescription)"
        launchAtLogin = oldValue
      }
    }
  }
  func readLoginItem() { launchAtLogin = SMAppService.mainApp.status == .enabled }
  /// What the menu bar item shows beside the icon.
  var readouts: Set<Readout> {
    didSet { defaults.set(readouts.map(\.rawValue), forKey: "readouts") }
  }
  /// The latest whole-Mac sample, while a readout that needs one is on.
  var system: SystemSample?
  func binding(_ readout: Readout) -> Bool { readouts.contains(readout) }
  func set(_ readout: Readout, _ on: Bool) {
    if on { readouts.insert(readout) } else { readouts.remove(readout) }
  }
  var notice: String?
  var search = ""
  /// Origin filter (Claude Code, Codex, Terminal…); nil shows everything.
  var filter: String?
  var scan: Scan?
  var error: String?
  var busy = false
  var selected: Identity?
  var showTree = false
  var renaming: Identity?
  var renameText = ""
  /// Row whose hover button is waiting for its second click, and the signal it will send.
  var armed: (id: Identity, signal: Signal)?
  var acting: Set<Identity> = []
  var messages: [Identity: String] = [:]
  /// Workloads that survived a Stop and now offer Force Quit prominently.
  var lingering: Set<Identity> = []
  var listHeight: Double = 0
  var chromeHeight: Double = 0
  var historyVersion = 0
  /// Counts panel openings, so the search field can take focus each time.
  var opened = 0
  var visible = false
  @ObservationIgnored let history = History()
  @ObservationIgnored let notifier = Notifier()
  var isQuiet: Bool {
    scan?.workloads.allSatisfy { $0.section == .system || $0.section == .apps } == true
      && error == nil
      && history.recent.isEmpty
  }
  /// The panel's natural height: everything above and below the list, plus the list itself.
  var desiredHeight: Double { chromeHeight + listHeight }
  @ObservationIgnored private var refreshPending = false
  @ObservationIgnored private var refreshDeferred = false
  @ObservationIgnored var scrolling = false {
    didSet {
      guard !scrolling, refreshDeferred else { return }
      refreshDeferred = false
      refresh()
    }
  }
  @ObservationIgnored private var armTimer: Task<Void, Never>?
  @ObservationIgnored private let monitor = ProcessMonitor()
  @ObservationIgnored private var exits: [Identity: DispatchSourceProcess] = [:]
  /// Identities Bollard itself signalled recently, so their exit is not reported as unexpected.
  @ObservationIgnored private var ownStops: [Identity: Date] = [:]

  init() {
    sort = WorkloadSort(rawValue: defaults.string(forKey: "sort") ?? "Name") ?? .name
    collapsed = Set(
      defaults.stringArray(forKey: "collapsed.4") ?? [
        "Agent commands", "System & tools", "Recent",
      ])
    readouts = Set(
      (defaults.stringArray(forKey: "readouts") ?? ["servers"]).compactMap(Readout.init))
    notify = defaults.object(forKey: "notify") as? Bool ?? true
    hotkeyEnabled = defaults.object(forKey: "hotkey") as? Bool ?? true
  }

  // MARK: Rows

  func name(_ w: Workload) -> String { history.displayName(w) }
  func pinned(_ w: Workload) -> Bool { history.isPinned(w) }
  var rows: [Workload] {
    (scan?.workloads ?? []).filter { w in
      (filter == nil || w.origin == filter)
        && (search.isEmpty
          || "\(name(w)) \(w.name) \(w.detail) \(w.kind.name) \(w.ports.map { ":\(String($0))" }.joined(separator: " ")) \(w.provenance) \(w.origin) \(w.branch ?? "") \(w.root.pid)"
            .localizedCaseInsensitiveContains(search))
    }.sorted { a, b in
      let pa = pinned(a)
      let pb = pinned(b)
      if pa != pb { return pa }
      switch sort {
      case .name: return (name(a).lowercased(), a.root.pid) < (name(b).lowercased(), b.root.pid)
      case .port: return (a.ports.first ?? .max, a.root.pid) < (b.ports.first ?? .max, b.root.pid)
      case .memory: return a.memory == b.memory ? a.root.pid < b.root.pid : a.memory > b.memory
      case .cpu: return a.cpu == b.cpu ? a.root.pid < b.root.pid : a.cpu > b.cpu
      case .uptime: return a.root.identity.start < b.root.identity.start
      }
    }
  }
  func lane(_ section: Lane) -> [Workload] { rows.filter { $0.section == section } }
  var servers: [Workload] { lane(.servers) }
  var recent: [RecentServer] {
    let live = Set((scan?.workloads ?? []).map(History.key))
    return history.recent.filter {
      !live.contains($0.id) && FileManager.default.fileExists(atPath: $0.directory)
    }
  }
  /// Launchers present among dev workloads, with counts, for the filter pills.
  var origins: [(name: String, count: Int)] {
    let dev = (scan?.workloads ?? []).filter { $0.section == .servers || $0.section == .background }
    return Dictionary(grouping: dev, by: \.origin).map { ($0.key, $0.value.count) }.sorted {
      $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
    }
  }
  func open(_ section: Lane) -> Bool { !collapsed.contains(section.rawValue) || !search.isEmpty }
  func toggle(_ section: String) {
    if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
  }
  /// Rows in display order, for keyboard navigation.
  var visibleRows: [Workload] {
    Lane.allCases.flatMap { section in open(section) ? lane(section) : [] }
  }
  func select(_ w: Workload) {
    selected = selected == w.id ? nil : w.id
    armed = nil
  }
  func workload(_ id: Identity) -> Workload? { scan?.workloads.first { $0.id == id } }
  var current: Workload? { selected.flatMap(workload) }

  // MARK: Scanning

  func refresh() {
    // A new scan redraws every row. While the list is moving that shows up as a dropped frame,
    // so it waits for the scroll to settle.
    guard !scrolling else {
      refreshDeferred = true
      return
    }
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
        let next = try await monitor.scan(sampling: visible, apps: openApplications())
        let previous = scan
        scan = next
        error = nil
        let ids = Set(next.workloads.map(\.id))
        if let id = selected, !ids.contains(id) { selected = nil }
        if let a = armed, !ids.contains(a.id) { armed = nil }
        if let r = renaming, !ids.contains(r) { renaming = nil }
        messages = messages.filter { ids.contains($0.key) }
        lingering = lingering.intersection(ids)
        if let previous { reconcile(previous, next) }
        observeExits(next.workloads)
      } catch { self.error = error.localizedDescription }
    }
  }
  /// Records servers that went away and announces starts and unexpected stops.
  private func reconcile(_ previous: Scan, _ next: Scan) {
    let before = Dictionary(uniqueKeysWithValues: previous.workloads.map { ($0.id, $0) })
    let after = Set(next.workloads.map(\.id))
    ownStops = ownStops.filter { Date().timeIntervalSince($0.value) < 30 }
    for (id, w) in before where !after.contains(id) {
      history.remember(w)
      historyVersion += 1
      if notify, w.section == .servers, ownStops[id] == nil {
        notifier.post(
          title: "\(name(w)) stopped",
          body:
            "\(w.kind.name) on \(w.ports.map { ":\(String($0))" }.joined(separator: " ")) exited. Started by \(w.origin).",
          id: "stop-\(id.pid)-\(id.start)")
      }
    }
    if notify {
      for w in next.workloads where w.section == .servers && before[w.id] == nil {
        notifier.post(
          title: "\(name(w)) is up",
          body:
            "\(w.kind.name) on \(w.ports.map { ":\(String($0))" }.joined(separator: " ")) · \(w.origin)",
          id: "start-\(w.id.pid)-\(w.id.start)")
      }
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
    ownStops[w.id] = Date()
    if w.section == .apps, let app = NSRunningApplication(processIdentifier: w.root.pid) {
      let ok = signal == .kill ? app.forceTerminate() : app.terminate()
      notice =
        ok
        ? "\(signal == .kill ? "Force quit" : "Asked to quit") \(name(w))."
        : "\(name(w)) refused to quit."
      messages[w.id] = nil
      Task {
        try? await Task.sleep(for: .seconds(1.5))
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
            "\(signal == .kill ? "Force quit" : "Stopped") \(name(w)) · \(outcome.signalled.count) process\(outcome.signalled.count == 1 ? "" : "es")."
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
  /// Stops every server currently shown, so the origin filter and search decide the scope.
  func stopAll(_ signal: Signal) {
    let targets = servers.filter { $0.blocked == nil && !acting.contains($0.id) }
    guard !targets.isEmpty else {
      notice = "No servers to stop."
      return
    }
    for t in targets { ownStops[t.id] = Date() }
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
      notice =
        "Stopped \(stopped) of \(targets.count) server\(targets.count == 1 ? "" : "s")"
        + (filter.map { " from \($0)" } ?? "") + "."
    }
  }
  func unload(_ w: Workload) {
    guard let label = w.launchdLabel else { return }
    ownStops[w.id] = Date()
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
    ownStops[w.id] = Date()
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
        try await Launcher.relaunch(w)
        notice = "Launch command opened in Terminal for \(name(w))."
      } catch { messages[w.id] = error.localizedDescription }
    }
  }
  func launch(_ r: RecentServer) {
    Task {
      do {
        try await Launcher.relaunch(r)
        notice = "Launching \(r.name) in Terminal."
      } catch { notice = error.localizedDescription }
    }
  }
  func forget(_ r: RecentServer) {
    history.forget(r.id)
    historyVersion += 1
  }
  func togglePin(_ w: Workload) {
    history.togglePin(w)
    historyVersion += 1
  }
  func beginRename(_ w: Workload) {
    renaming = w.id
    renameText = name(w)
    selected = w.id
  }
  func commitRename(_ w: Workload) {
    history.rename(w, to: renameText)
    renaming = nil
    historyVersion += 1
  }
  func agentHere(_ path: String, _ w: Workload) {
    Task {
      do { try await Launcher.agent(path, in: w.root.cwd) } catch {
        notice = error.localizedDescription
      }
    }
  }
  func open(port: Int) { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
  /// Return in the search field: open the selected or first server in the browser, else expand it.
  func activate() {
    guard let w = current ?? visibleRows.first else { return }
    if let url = w.url { NSWorkspace.shared.open(url) } else { selected = w.id }
  }
  func copy(_ s: String, note: String = "Copied.") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    notice = note
  }

  // MARK: Keyboard

  /// Returns true when the key was consumed.
  func handle(_ event: NSEvent) -> Bool {
    // Arrow keys carry the function and numeric-pad flags; only the real modifiers matter here.
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if renaming != nil { return false }
    let rows = visibleRows
    switch (event.keyCode, flags) {
    case (125, []): move(1, in: rows)
    case (126, []): move(-1, in: rows)
    case (51, [.command]):
      guard let w = current, w.blocked == nil else { return false }
      act(w, .terminate)
    case (51, [.command, .shift]):
      guard let w = current, w.blocked == nil else { return false }
      act(w, .kill)
    case (31, [.command]):
      guard let url = current?.url else { return false }
      NSWorkspace.shared.open(url)
    case (15, [.command]): refresh()
    case (35, [.command]):  // ⌘P pin
      guard let w = current else { return false }
      togglePin(w)
    default: return false
    }
    return true
  }
  private func move(_ delta: Int, in rows: [Workload]) {
    guard !rows.isEmpty else { return }
    var index: Int = delta > 0 ? 0 : rows.count - 1
    if let current = rows.firstIndex(where: { $0.id == selected }) { index = current + delta }
    index = max(0, min(rows.count - 1, index))
    selected = rows[index].id
  }
}
