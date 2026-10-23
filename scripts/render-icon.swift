import AppKit

// Bollard: a mooring post with a rope loop on a deep blue ground.
func render(_ size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let s = size
  let inset = s * 0.045  // macOS icon grid margin
  let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let ground = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
  let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.33, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.66, alpha: 1),
  ])!
  gradient.draw(in: ground, angle: 90)
  // Subtle horizon line (water)
  NSColor.white.withAlphaComponent(0.08).setFill()
  NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY + rect.height * 0.30, width: rect.width, height: rect.height * 0.012)).fill()
  // Geometry
  let postW = s * 0.26
  let postH = s * 0.50
  let postX = s / 2 - postW / 2
  let postY = rect.minY + rect.height * 0.20
  let ropeY = postY + postH * 0.50
  let rope = NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.20, alpha: 1)
  let ropeWidth = s * 0.058
  // Rope: the loop's far half passes behind the post, the near half in front.
  let loop = NSRect(x: s / 2 - postW * 0.95, y: ropeY - postW * 0.36, width: postW * 1.9, height: postW * 0.72)
  let back = NSBezierPath()
  back.lineWidth = ropeWidth
  back.lineCapStyle = .round
  back.appendArc(withCenter: NSPoint(x: loop.midX, y: loop.midY), radius: 1, startAngle: 0, endAngle: 0)
  back.removeAllPoints()
  back.appendOval(in: loop)
  rope.withAlphaComponent(0.75).setStroke()
  back.stroke()
  // Post
  let post = NSBezierPath(roundedRect: NSRect(x: postX, y: postY, width: postW, height: postH), xRadius: postW * 0.18, yRadius: postW * 0.18)
  NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
  post.fill()
  NSColor(calibratedWhite: 0, alpha: 0.10).setFill()
  NSBezierPath(roundedRect: NSRect(x: s / 2 + postW * 0.10, y: postY, width: postW * 0.40, height: postH - postW * 0.2), xRadius: postW * 0.18, yRadius: postW * 0.18).fill()
  let cap = NSBezierPath(ovalIn: NSRect(x: s / 2 - postW * 0.72, y: postY + postH - postW * 0.30, width: postW * 1.44, height: postW * 0.60))
  NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
  cap.fill()
  // Near half of the loop, in front of the post, with the tail running off to the bottom left.
  let front = NSBezierPath()
  front.lineWidth = ropeWidth
  front.lineCapStyle = .round
  front.lineJoinStyle = .round
  front.appendArc(withCenter: NSPoint(x: loop.midX, y: loop.midY), radius: loop.width / 2, startAngle: 180, endAngle: 360, clockwise: false)
  let tail = NSBezierPath()
  tail.lineWidth = ropeWidth
  tail.lineCapStyle = .round
  tail.move(to: NSPoint(x: loop.minX + ropeWidth * 0.2, y: loop.midY))
  tail.curve(to: NSPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.13),
             controlPoint1: NSPoint(x: loop.minX - postW * 0.2, y: loop.midY - postW * 0.9),
             controlPoint2: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.30))
  rope.setStroke()
  // Squash the front arc vertically to match the oval loop.
  var squash = AffineTransform.identity
  squash.translate(x: loop.midX, y: loop.midY)
  squash.scale(x: 1, y: loop.height / loop.width)
  squash.translate(x: -loop.midX, y: -loop.midY)
  front.transform(using: squash)
  front.stroke()
  tail.stroke()
  image.unlockFocus()
  return image
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  let image = render(CGFloat(px))
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("rendered")
