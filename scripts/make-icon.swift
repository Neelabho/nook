// Renders Nook's app icon (dark squircle, notch, spinning record, shelf tray) to an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.05, alpha: 1)])?.draw(in: squircle, angle: -90)
    squircle.addClip()

    // Notch.
    let nw = body.width * 0.42, nh = body.height * 0.13
    let notch = NSBezierPath(roundedRect: NSRect(x: body.midX - nw / 2, y: body.maxY - nh, width: nw, height: nh * 2), xRadius: nh * 0.6, yRadius: nh * 0.6)
    NSColor.black.setFill(); notch.fill()

    // Record.
    let rr = body.width * 0.27
    let c = NSPoint(x: body.midX + body.width * 0.1, y: body.midY - body.height * 0.02)
    let disc = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    NSColor(white: 0.02, alpha: 1).setFill(); disc.fill()
    var r = rr * 0.95
    while r > rr * 0.4 {
        NSColor(white: 1, alpha: 0.07).setStroke()
        let g = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); g.lineWidth = max(1, s / 512); g.stroke()
        r -= s / 90
    }
    let lr = rr * 0.36
    let label = NSBezierPath(ovalIn: NSRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2))
    NSGradient(colors: [NSColor(red: 0.55, green: 0.78, blue: 1, alpha: 1), NSColor(red: 0.35, green: 0.5, blue: 0.95, alpha: 1)])?.draw(in: label, angle: -45)
    NSColor(white: 0.85, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - lr * 0.12, y: c.y - lr * 0.12, width: lr * 0.24, height: lr * 0.24)).fill()

    // Shelf tray card in front.
    let card = NSRect(x: body.minX + body.width * 0.12, y: body.minY + body.height * 0.14, width: body.width * 0.36, height: body.height * 0.44)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: s * 0.03, yRadius: s * 0.03)
    NSColor(white: 0.95, alpha: 1).setFill(); cardPath.fill()
    NSColor(white: 0.75, alpha: 1).setFill()
    for i in 0..<4 {
        let w = card.width * (i == 3 ? 0.45 : 0.7)
        NSBezierPath(roundedRect: NSRect(x: card.minX + card.width * 0.15, y: card.maxY - card.height * (0.22 + CGFloat(i) * 0.16), width: w, height: card.height * 0.06),
                     xRadius: s * 0.006, yRadius: s * 0.006).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px)?.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("Wrote \(out.path)")
