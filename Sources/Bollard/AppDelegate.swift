import AppKit
import BollardCore
import Combine
import ServiceManagement
import SwiftUI

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
  var exposedTitle = false
  lazy var hotkey = Hotkey { [weak self] in self?.toggle() }

  func applicationDidFinishLaunching(_ note: Notification) {
    NSApp.setActivationPolicy(.accessory)
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(
      systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Bollard"
    )
    item.button?.target = self
    item.button?.action = #selector(toggle)
    item.button?.toolTip = "Bollard — servers on your Mac · \(Hotkey.description)"
    panel.title = "Bollard"
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
        if store.renaming != nil {
          store.renaming = nil
          return nil
        }
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
    if store.hotkeyEnabled { hotkey.register() }
    if store.notify { store.notifier.prepare() }
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
    if store.hotkeyEnabled { hotkey.register() } else { hotkey.unregister() }
    let servers = store.scan?.workloads.filter { $0.section == .servers } ?? []
    // Never tint the button itself: a tint drops it out of the menu bar's vibrant rendering and
    // it draws black. The template icon stays as is; only the count turns orange when a dev
    // server is reachable from the network.
    let exposed = servers.contains { $0.exposed }
    let title = servers.isEmpty ? "" : " \(servers.count)"
    if let button = item.button,
      button.title != title || (button.attributedTitle.length > 0) != !title.isEmpty
        || exposedTitle != exposed
    {
      exposedTitle = exposed
      if title.isEmpty {
        button.attributedTitle = NSAttributedString()
      } else {
        button.attributedTitle = NSAttributedString(
          string: title,
          attributes: [
            .foregroundColor: exposed ? NSColor.systemOrange : NSColor.labelColor,
            .font: NSFont.menuBarFont(ofSize: 0),
          ])
      }
    }
    guard store.visible, let button = item.button, let window = button.window,
      let screen = window.screen
    else { return }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    // Content measures itself; fall back to a rough estimate before the first layout.
    var desired: Double = store.chromeHeight + store.listHeight + 32
    if store.listHeight == 0 { desired = 196 + Double(max(store.visibleRows.count, 1)) * 50 }
    let frame = PanelPlacement.frame(
      anchor: anchor, screen: screen.visibleFrame,
      desiredHeight: store.compact ? store.chromeHeight + 4 : desired,
      desiredWidth: store.compact ? 320 : 500)
    if abs(panel.frame.height - frame.height) > 1 || abs(panel.frame.minX - frame.minX) > 1
      || abs(panel.frame.width - frame.width) > 1
    {
      panel.setFrame(frame, display: true)
    }
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
    store.renaming = nil
    store.search = ""
  }
}

extension NSView {
  var firstTextField: NSView? {
    if self is NSTextField { return self }
    for view in subviews { if let found = view.firstTextField { return found } }
    return nil
  }
}
