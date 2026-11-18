#if DEBUG
  import AppKit
  import BollardCore
  import SwiftUI

  /// Development aid, debug builds only: draws the panel for the live process table into a PNG
  /// without putting a window on screen, so layout can be reviewed while the Mac is in use.
  /// `swift run Bollard --render out.png [name-or-pid-to-expand] [search]`
  @MainActor enum Render {
    static func run(to path: String, expanding target: String?, search: String, light: Bool)
      throws
    {
      _ = NSApplication.shared
      let store = Store()
      func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
      }
      // Two scans, so CPU has a baseline.
      store.refresh()
      spin(1.2)
      store.refresh()
      spin(0.4)
      store.search = search
      if let target {
        store.collapsed = []
        store.selected =
          store.visibleRows.first {
            $0.name == target || String($0.root.pid) == target || $0.section.rawValue == target
          }?.id
      }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 600), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
      let host = NSHostingView(
        rootView: Panel(store: store).background(Color(nsColor: .windowBackgroundColor)))
      window.contentView = host
      spin(0.5)
      window.setContentSize(NSSize(width: Theme.width, height: min(store.desiredHeight, 1600)))
      spin(0.5)
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw SafetyError("Could not allocate the bitmap.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
  }
#endif
