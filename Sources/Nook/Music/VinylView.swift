import AppKit
import NookCore
import QuartzCore
import SwiftUI

/// A vinyl record rendered once into a bitmap and spun by Core Animation in the render server,
/// so rotation costs essentially no app CPU. Rotation pauses in place (layer speed 0) when playback
/// pauses, and is disabled entirely for Reduce Motion.
struct VinylView: NSViewRepresentable {
    var label: NSImage?
    var spinning: Bool
    var diameter: CGFloat

    func makeNSView(context: Context) -> VinylNSView { VinylNSView() }

    func updateNSView(_ view: VinylNSView, context: Context) {
        view.update(label: label, spinning: spinning, diameter: diameter)
    }
}

/// Remembers the record's angle while the panel is closed, so reopening continues the rotation
/// instead of snapping back to 0°.
@MainActor
enum VinylRotationMemory {
    static let secondsPerTurn = VinylRotation.secondsPerTurn
    private static var angle: Double = 0
    private static var savedAt = Date()
    private static var wasSpinning = false

    static func save(angle: Double, spinning: Bool) {
        self.angle = angle
        savedAt = Date()
        wasSpinning = spinning
    }

    /// Angle to resume from; if the record was spinning, account for the time it was off screen.
    static func resumeAngle(spinningNow: Bool) -> Double {
        VinylRotation.resumeAngle(saved: angle, savedAt: savedAt, wasSpinning: wasSpinning, spinningNow: spinningNow, now: Date())
    }
}

final class VinylNSView: NSView {
    private let disc = CALayer()
    private let sheen = CALayer()
    private var currentLabel: NSImage?
    private var currentDiameter: CGFloat = 0
    private var hasAnimation = false
    private var isSpinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        layer?.addSublayer(sheen)
        disc.contentsGravity = .resizeAspect
        sheen.contentsGravity = .resizeAspect
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds
        sheen.frame = bounds
        CATransaction.commit()
    }

    func update(label: NSImage?, spinning: Bool, diameter: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        if label !== currentLabel || diameter != currentDiameter {
            currentLabel = label
            currentDiameter = diameter
            disc.contents = Self.renderDisc(diameter: diameter, scale: scale, label: label)
            sheen.contents = Self.renderSheen(diameter: diameter, scale: scale)
        }
        setSpinning(spinning)
    }

    private func setSpinning(_ spinning: Bool) {
        guard spinning != isSpinning || !hasAnimation else { return }
        isSpinning = spinning
        if !hasAnimation {
            let start = VinylRotationMemory.resumeAngle(spinningNow: spinning)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = start
            spin.toValue = start - 2 * Double.pi
            spin.duration = VinylRotationMemory.secondsPerTurn
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: "spin")
            hasAnimation = true
            disc.speed = 0
            disc.timeOffset = 0
        }
        if spinning {
            let paused = disc.timeOffset
            disc.speed = 1
            disc.timeOffset = 0
            disc.beginTime = 0
            disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            let now = disc.convertTime(CACurrentMediaTime(), from: nil)
            disc.speed = 0
            disc.timeOffset = now
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure Core Animation stops entirely when the view is not on screen (remembering the angle).
        if window == nil {
            if hasAnimation, let angle = disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double {
                MainActor.assumeIsolated { VinylRotationMemory.save(angle: angle, spinning: isSpinning) }
            }
            disc.removeAllAnimations()
            hasAnimation = false
            isSpinning = false
        }
    }

    // MARK: Drawing

    static func renderDisc(diameter: CGFloat, scale: CGFloat, label: NSImage?) -> CGImage? {
        let px = Int(diameter * scale)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(px)
        let c = CGPoint(x: size / 2, y: size / 2)
        let r = size / 2

        // Body.
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.clip()
        let body = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.035, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(body, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])

        // Fine grooves.
        var radius = r * 0.97
        var i = 0
        while radius > r * 0.37 {
            let alpha = (i % 3 == 0) ? 0.09 : 0.035
            ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
            ctx.setLineWidth(max(0.5, scale * 0.35))
            ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            radius -= scale * 1.15
            i += 1
        }
        // Track gaps.
        for f in [0.82, 0.66, 0.52] {
            let gr = r * f
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
            ctx.setLineWidth(scale * 1.2)
            ctx.strokeEllipse(in: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2))
        }

        // Label.
        let lr = r * 0.34
        let labelRect = CGRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)
        ctx.saveGState()
        ctx.addEllipse(in: labelRect)
        ctx.clip()
        if let label, let cg = label.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: labelRect)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.18))
            ctx.fill(labelRect)
        } else {
            let paper = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.93, green: 0.42, blue: 0.27, alpha: 1),
                                                               CGColor(red: 0.72, green: 0.2, blue: 0.24, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(paper, start: CGPoint(x: labelRect.minX, y: labelRect.maxY), end: CGPoint(x: labelRect.maxX, y: labelRect.minY), options: [])
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
            ctx.setLineWidth(scale * 0.6)
            let ir = lr * 0.72
            ctx.strokeEllipse(in: CGRect(x: c.x - ir, y: c.y - ir, width: ir * 2, height: ir * 2))
        }
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
        ctx.setLineWidth(scale)
        ctx.strokeEllipse(in: labelRect)

        // Spindle hole.
        let sr = r * 0.035
        let spindle = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.85, alpha: 1), CGColor(gray: 0.45, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - sr, y: c.y - sr, width: sr * 2, height: sr * 2))
        ctx.clip()
        ctx.drawRadialGradient(spindle, startCenter: CGPoint(x: c.x - sr * 0.3, y: c.y + sr * 0.3), startRadius: 0, endCenter: c, endRadius: sr, options: [])
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Static reflection (light doesn't rotate with the record).
    static func renderSheen(diameter: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(diameter * scale)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(px)
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        let inner = size * 0.17
        ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        ctx.clip(using: .evenOdd)
        // Two soft light wedges on opposite sides, like a studio light on a real record.
        let r = size / 2
        for (start, sweep, strength) in [(CGFloat.pi * 0.18, CGFloat.pi * 0.16, 0.12), (CGFloat.pi * 1.18, CGFloat.pi * 0.12, 0.08)] {
            ctx.saveGState()
            let wedge = CGMutablePath()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: r, startAngle: start, endAngle: start + sweep, clockwise: false)
            wedge.closeSubpath()
            ctx.addPath(wedge)
            ctx.clip()
            let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: strength), CGColor(gray: 1, alpha: strength * 0.3)] as CFArray
            if let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0.3, 0.75, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
