import AppKit
import BollardCore
import Combine
import Foundation
import SwiftUI

enum WorkloadSort: String, CaseIterable {
  case name = "Name"
  case port = "Port"
  case memory = "Memory"
  case cpu = "CPU"
  case uptime = "Uptime"
}

@MainActor final class Store: ObservableObject {
  private let defaults = UserDefaults.standard
  @Published var sort: WorkloadSort {
    didSet { defaults.set(sort.rawValue, forKey: "sort") }
  }
  @Published var collapsed: Set<String> {
    didSet { defaults.set(Array(collapsed), forKey: "collapsed") }
  }
  @Published var notify: Bool {
    didSet {
      defaults.set(notify, forKey: "notify")
      if notify { notifier.prepare() }
    }
  }
  @Published var hotkeyEnabled: Bool {
    didSet { defaults.set(hotkeyEnabled, forKey: "hotkey") }
  }
  @Published var notice: String?
  @Published var search = ""
  /// Origin filter (Claude Code, Codex, Terminal…); nil shows everything.
  @Published var filter: String?
  @Published var scan: Scan?
  @Published var error: String?
  @Published var busy = false
  @Published var selected: Identity?
  @Published var showTree = false
  @Published var renaming: Identity?
  @Published var renameText = ""
  /// Row whose hover button is waiting for its second click, and the signal it will send.
  @Published var armed: (id: Identity, signal: Signal)?
  @Published var acting: Set<Identity> = []
  @Published var messages: [Identity: String] = [:]
  /// Workloads that survived a Stop and now offer Force Quit prominently.
  @Published var lingering: Set<Identity> = []
  @Published var listHeight: Double = 0
  @Published var chromeHeight: Double = 0
  @Published var historyVersion = 0
  var visible = false
  var searchFocused = false
  let history = History()
  let notifier = Notifier()
  var isQuiet: Bool {
    scan?.workloads.allSatisfy { $0.section == .system } == true && error == nil
      && history.recent.isEmpty
  }
  var compact: Bool { isQuiet && notice == nil && acting.isEmpty }
  private var refreshPending = false
  private var armTimer: Task<Void, Never>?
  private let monitor = ProcessMonitor()
  private var exits: [Identity: DispatchSourceProcess] = [:]
  /// Identities Bollard itself signalled recently, so their exit is not reported as unexpected.
  private var ownStops: [Identity: Date] = [:]

  init() {
    sort = WorkloadSort(rawValue: defaults.string(forKey: "sort") ?? "Name") ?? .name
    collapsed = Set(
      defaults.stringArray(forKey: "collapsed") ?? ["Apps", "System & tools", "Recent"])
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
          || "\(name(w)) \(w.name) \(w.kind.name) \(w.ports.map { ":\(String($0))" }.joined(separator: " ")) \(w.provenance) \(w.origin) \(w.branch ?? "") \(w.root.pid)"
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
  /// Rows in display order, for keyboard navigation.
  var visibleRows: [Workload] {
    Lane.allCases.flatMap { section in section == .servers || open(section) ? lane(section) : [] }
  }
  func workload(_ id: Identity) -> Workload? { scan?.workloads.first { $0.id == id } }
  var current: Workload? { selected.flatMap(workload) }

  // MARK: Scanning

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
      guard let w = current, let port = w.ports.first else { return false }
      open(port: port)
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
