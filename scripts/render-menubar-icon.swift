import AppKit
// Menu bar glyph candidates for Bollard, drawn on an 18-point grid.
func render(_ scale: CGFloat, variant: Int) -> NSBitmapImageRep {
  let px = Int(18 * scale)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let u = CGFloat(px) / 18  // one point
  NSColor.black.setFill()
  NSColor.black.setStroke()
  func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x * u, y: y * u, width: w * u, height: h * u), xRadius: r * u, yRadius: r * u)
  }
  switch variant {
  case 1:
    // Classic profile: dome cap, collar, tapered column, base plate. One continuous silhouette.
    let column = NSBezierPath()
    column.move(to: NSPoint(x: 6.0 * u, y: 3.0 * u))
    column.line(to: NSPoint(x: 12.0 * u, y: 3.0 * u))
    column.line(to: NSPoint(x: 11.2 * u, y: 11.5 * u))
    column.line(to: NSPoint(x: 6.8 * u, y: 11.5 * u))
    column.close()
    column.fill()
    rr(4.5, 11.0, 9.0, 2.2, 1.1).fill()  // collar
    NSBezierPath(ovalIn: NSRect(x: 4.5 * u, y: 12.2 * u, width: 9.0 * u, height: 5.6 * u)).fill()  // dome
    rr(3.0, 1.0, 12.0, 2.4, 1.2).fill()  // base plate
  case 2:
    // Same profile with a mooring line draped over the collar.
    let column = NSBezierPath()
    column.move(to: NSPoint(x: 6.0 * u, y: 3.0 * u))
    column.line(to: NSPoint(x: 12.0 * u, y: 3.0 * u))
    column.line(to: NSPoint(x: 11.2 * u, y: 11.5 * u))
    column.line(to: NSPoint(x: 6.8 * u, y: 11.5 * u))
    column.close()
    column.fill()
    rr(4.5, 11.0, 9.0, 2.2, 1.1).fill()
    NSBezierPath(ovalIn: NSRect(x: 4.5 * u, y: 12.2 * u, width: 9.0 * u, height: 5.6 * u)).fill()
    rr(3.0, 1.0, 12.0, 2.4, 1.2).fill()
    let rope = NSBezierPath()
    rope.lineWidth = 1.6 * u
    rope.lineCapStyle = .round
    rope.move(to: NSPoint(x: 13.5 * u, y: 10.2 * u))
    rope.curve(to: NSPoint(x: 16.5 * u, y: 3.0 * u), controlPoint1: NSPoint(x: 16.5 * u, y: 9.5 * u), controlPoint2: NSPoint(x: 17.0 * u, y: 6.0 * u))
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    let gap = rope.copy() as! NSBezierPath
    gap.lineWidth = 3.2 * u
    gap.stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    rope.stroke()
  case 4, 5:
    // Capsule post with a mooring ring around it; a clear halo keeps the ring legible.
    let postW: CGFloat = 6.0
    let post = rr(9 - postW / 2, 1.0, postW, 16.0, postW / 2)
    post.fill()
    if variant == 5 { rr(4.5, 14.2, 9.0, 2.8, 1.4).fill() }  // mushroom cap
    let ring = NSRect(x: 2.5 * u, y: (variant == 4 ? 6.2 : 5.2) * u, width: 13.0 * u, height: 5.2 * u)
    let halo = NSBezierPath(ovalIn: ring)
    halo.lineWidth = 3.6 * u
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    halo.stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    let stroke = NSBezierPath(ovalIn: ring)
    stroke.lineWidth = 1.7 * u
    stroke.stroke()
    // Re-fill the part of the post that sits in front of the far half of the ring.
    let front = NSBezierPath(rect: NSRect(x: (9 - postW / 2) * u, y: ring.minY - 0.2 * u, width: postW * u, height: ring.height / 2 + 1.2 * u))
    front.addClip()
  case 6, 7:
    // Back half of the ring, the post, then the front half with a halo where it crosses the post.
    let postW: CGFloat = 6.4
    let ring = NSRect(x: 2.2 * u, y: 5.6 * u, width: 13.6 * u, height: 5.4 * u)
    func arc(_ from: CGFloat, _ to: CGFloat, width: CGFloat) -> NSBezierPath {
      let p = NSBezierPath()
      p.lineWidth = width * u
      p.lineCapStyle = .butt
      p.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: from, endAngle: to)
      var t = AffineTransform.identity
      t.translate(x: ring.midX, y: ring.midY)
      t.scale(x: 1, y: ring.height / ring.width)
      t.translate(x: -ring.midX, y: -ring.midY)
      p.transform(using: t)
      return p
    }
    arc(0, 180, width: 1.7).stroke()
    rr(9 - postW / 2, 1.2, postW, 15.6, postW / 2).fill()
    if variant == 7 { rr(4.6, 13.6, 8.8, 3.0, 1.5).fill() }
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    arc(180, 360, width: 3.9).stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    arc(180, 360, width: 1.7).stroke()
  case 8, 9:
    // Tuned: thinner ring, narrow halo, the post stays whole below the ring.
    let postW: CGFloat = 6.4
    let ring = NSRect(x: 2.4 * u, y: 6.9 * u, width: 13.2 * u, height: 4.8 * u)
    func arc(_ from: CGFloat, _ to: CGFloat, width: CGFloat) -> NSBezierPath {
      let p = NSBezierPath()
      p.lineWidth = width * u
      p.lineCapStyle = .butt
      p.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: from, endAngle: to)
      var t = AffineTransform.identity
      t.translate(x: ring.midX, y: ring.midY)
      t.scale(x: 1, y: ring.height / ring.width)
      t.translate(x: -ring.midX, y: -ring.midY)
      p.transform(using: t)
      return p
    }
    arc(0, 180, width: 1.5).stroke()
    rr(9 - postW / 2, 1.0, postW, 16.0, postW / 2).fill()
    if variant == 9 { rr(5.0, 13.8, 8.0, 2.8, 1.4).fill() }
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    arc(180, 360, width: 2.9).stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    arc(180, 360, width: 1.5).stroke()
  default:
    // Minimal: rounded post with a wide cap, like a map pictogram.
    rr(6.0, 1.5, 6.0, 12.0, 1.5).fill()
    rr(3.5, 12.5, 11.0, 4.0, 2.0).fill()
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for v in 1...9 {
  try! render(8, variant: v).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("glyph\(v)-preview.png"))
  try! render(2, variant: v).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("glyph\(v)@2x.png"))
  try! render(1, variant: v).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("glyph\(v).png"))
}
print("ok")
