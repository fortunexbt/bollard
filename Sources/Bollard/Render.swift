#if DEBUG
  import AppKit
  import BollardCore
  import QuartzCore
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
      // Two scans as an open panel makes them, so memory is sampled and CPU has a baseline.
      store.visible = true
      store.refresh()
      spin(1.2)
      store.refresh()
      spin(0.4)
      store.search = search
      // Expanding lanes for the picture must not outlive it: the set is saved as a preference.
      let collapsed = store.collapsed
      defer { store.collapsed = collapsed }
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

  extension Render {
    /// Draws the menu bar item with every readout on, from live figures, on a dark and a light bar.
    static func bar(to path: String) throws {
      _ = NSApplication.shared
      let sampler = SystemSampler()
      let scan = try BollardCore.Scanner().scan(apps: openApplications())
      RunLoop.main.run(until: Date().addingTimeInterval(1))
      let servers = scan.workloads.filter { $0.section == .servers }
      let size = NSSize(width: 420, height: 24)
      let image = NSImage(size: NSSize(width: size.width, height: size.height * 2))
      image.lockFocus()
      for (row, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
          let title = MenuBar.title(
            Set(Readout.allCases), servers: max(servers.count, 2), exposed: false,
            agents: scan.workloads.filter { $0.section == .agents }.count, system: sampler.sample())
          let origin = NSPoint(x: 0, y: Double(row) * size.height)
          (row == 0 ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
          NSRect(origin: origin, size: size).fill()
          if let icon = AppDelegate.menuBarIcon {
            icon.draw(in: NSRect(x: 8, y: origin.y + 3, width: 18, height: 18))
          }
          title.draw(at: NSPoint(x: 28, y: origin.y + (size.height - title.size().height) / 2))
        }
      }
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        throw SafetyError("Could not draw the menu bar.")
      }
      try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
  }

  /// Development aid, debug builds only: scrolls the open panel's list end to end for a few
  /// seconds and reports how late each frame's turn on the main thread came. A late turn is a
  /// dropped frame. `swift run Bollard --show --scrolltest`
  @MainActor final class ScrollTest {
    private var gaps: [Double] = []
    private var hitches: [String] = []
    private var last = CACurrentMediaTime()
    private let started = CACurrentMediaTime()
    private var timer: Timer?
    init(in window: NSWindow, seconds: Double = 6) {
      // The list, not the row of filter pills: the scroll view with the tallest content.
      func all(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(all)
      }
      let lists = window.contentView.map(all) ?? []
      guard
        let scroll = lists.max(by: {
          ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }),
        let document = scroll.documentView
      else {
        print("no scroll view")
        exit(1)
      }
      let clip = scroll.contentView
      func layers(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).map(layers).reduce(0, +) }
      func views(_ view: NSView) -> Int { 1 + view.subviews.map(views).reduce(0, +) }
      print(
        "layers \(window.contentView?.layer.map(layers) ?? 0) · views \(window.contentView.map(views) ?? 0)"
      )
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let now = CACurrentMediaTime()
          self.gaps.append((now - self.last) * 1000)
          if now - self.last > 0.025 {
            self.hitches.append(
              String(format: "%.0f ms at %.1f s", (now - self.last) * 1000, now - self.started))
          }
          self.last = now
          let travel = max(1, document.frame.height - clip.bounds.height)
          let phase = (now - self.started).truncatingRemainder(dividingBy: 2) / 2
          clip.scroll(to: NSPoint(x: 0, y: travel * (phase < 0.5 ? phase * 2 : 2 - phase * 2)))
          scroll.reflectScrolledClipView(clip)
          if now - self.started > seconds {
            let sorted = self.gaps.sorted()
            print(
              String(
                format:
                  "frames %d · median %.1f ms · p95 %.1f ms · worst %.1f ms · over 25 ms: %d · list %.0f pt",
                sorted.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)],
                sorted.last ?? 0, sorted.filter { $0 > 25 }.count, document.frame.height))
            print("hitches: " + self.hitches.joined(separator: ", "))
            exit(0)
          }
        }
      }
    }
  }
#endif
