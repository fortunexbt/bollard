import AppKit

// Background for the Bollard disk image window, in the colours of the app icon.
// Usage: swift scripts/render-dmg-background.swift <out.tiff>
// Writes a 1x and a 2x bitmap and joins them into one multi-resolution TIFF with tiffutil.
// The layout constants must match scripts/dmg.sh.
let width: CGFloat = 660
let height: CGFloat = 400
let appX: CGFloat = 180
let applicationsX: CGFloat = 480
let iconY: CGFloat = 195  // icon centre, measured from the top of the window

// Finder draws icon labels in black even in dark mode, so the ground stays light in both
// appearances. The navy and orange come from the app icon.
let navy = NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.33, alpha: 1)
let mist = NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.97, alpha: 1)
let paper = NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1)
let rope = NSColor(calibratedRed: 0.93, green: 0.50, blue: 0.10, alpha: 1)

func draw(scale: CGFloat) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: width, height: height)  // 144 dpi at 2x, which tiffutil needs
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let bounds = NSRect(x: 0, y: 0, width: width, height: height)
  // Pale blue ground, lighter toward the top.
  NSGradient(colors: [mist, paper])!.draw(in: bounds, angle: 90)

  func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, kern: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: navy.withAlphaComponent(alpha),
      .kern: kern,
    ]
    let s = NSAttributedString(string: string, attributes: attributes)
    let w = s.size().width
    s.draw(at: NSPoint(x: (width - w) / 2, y: height - y))
  }
  text("Bollard", size: 26, weight: .semibold, alpha: 0.9, y: 64, kern: 0.3)
  text("Drag Bollard to Applications to install", size: 13, weight: .regular, alpha: 0.55, y: 92)

  // A light arrow between the two icons, in the rope orange: a thin shaft with an open head.
  let y = height - iconY
  let x0 = appX + 86
  let x1 = applicationsX - 86
  let arrow = NSBezierPath()
  arrow.lineWidth = 2
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  arrow.move(to: NSPoint(x: x0, y: y))
  arrow.line(to: NSPoint(x: x1, y: y))
  arrow.move(to: NSPoint(x: x1 - 12, y: y + 11))
  arrow.line(to: NSPoint(x: x1, y: y))
  arrow.line(to: NSPoint(x: x1 - 12, y: y - 11))
  rope.withAlphaComponent(0.6).setStroke()
  arrow.stroke()
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bollard-dmg-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
var parts: [String] = []
for (name, scale) in [("bg.tiff", CGFloat(1)), ("bg@2x.tiff", CGFloat(2))] {
  let rep = draw(scale: scale)
  let url = scratch.appendingPathComponent(name)
  try rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.none])!.write(to: url)
  parts.append(url.path)
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tool.arguments = ["-cathidpicheck"] + parts + ["-out", out.path]
try tool.run()
tool.waitUntilExit()
exit(tool.terminationStatus)
