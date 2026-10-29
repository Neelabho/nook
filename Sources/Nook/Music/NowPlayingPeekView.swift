import AppKit
import NookCore
import SwiftUI

/// The closed-notch "now playing" peek: album cover on the left wing, moving waves on the right,
/// the physical notch left empty in between. Shown only while playing (see `NowPlayingPeek`).
struct NowPlayingPeekView: View {
    let music: SpotifyService
    let settings: SettingsService
    let wing: CGFloat
    let height: CGFloat

    @State private var accent: Color = .white
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || settings.effectiveReduceMotion }
    private var artSide: CGFloat { max(14, height - 10) }
    /// Keeps the content clear of the closed shape's flared top corners.
    private var edgeInset: CGFloat { Nook.Metrics.closedTopRadius + 5 }

    var body: some View {
        HStack(spacing: 0) {
            cover
                .frame(width: artSide, height: artSide)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: wing, alignment: .leading)
                .padding(.leading, edgeInset)
            Spacer(minLength: 0)
            PeekWaves(color: accent, animating: !reduceMotion, maxHeight: artSide - 4)
                .frame(width: wing, alignment: .trailing)
                .padding(.trailing, edgeInset)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .task(id: music.artwork.map(ObjectIdentifier.init)) {
            accent = music.artwork.flatMap(PeekAccent.color(of:)) ?? .white
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nowPlayingLabel)
        .allowsHitTesting(false)   // hover and drops still go to the panel underneath
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork = music.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.12)
                Image(systemName: "music.note").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var nowPlayingLabel: String {
        guard let track = music.snapshot?.track else { return "Now playing" }
        return track.artist.isEmpty ? "Now playing: \(track.title)" : "Now playing: \(track.title) by \(track.artist)"
    }
}

/// Five rounded bars rising and falling out of step, like an audio meter. Static with Reduce Motion.
///
/// Animated with Core Animation keyframes that repeat in the window server, so Nook does no
/// per-frame work (a SwiftUI timeline at 30 fps cost about 6–7 % CPU; this costs about none).
struct PeekWaves: NSViewRepresentable {
    let color: Color
    let animating: Bool
    let maxHeight: CGFloat

    static let barCount = 5
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2.5
    private static let restingLevels: [CGFloat] = [0.45, 0.8, 0.6, 0.9, 0.5]
    private static let durations: [CFTimeInterval] = [1.13, 0.97, 1.31, 1.07, 1.21]
    /// Each bar's levels through one cycle; unrelated durations keep the bars out of step.
    private static let keyLevels: [[CGFloat]] = [
        [0.35, 0.9, 0.5, 0.75, 0.3, 0.35], [0.8, 0.4, 1.0, 0.55, 0.7, 0.8], [0.5, 0.75, 0.3, 0.95, 0.45, 0.5],
        [0.95, 0.55, 0.8, 0.35, 1.0, 0.95], [0.4, 0.7, 0.9, 0.45, 0.6, 0.4],
    ]

    func makeNSView(context: Context) -> WaveBarsView { WaveBarsView(count: Self.barCount) }

    func updateNSView(_ view: WaveBarsView, context: Context) {
        view.configure(color: NSColor(color).cgColor, animating: animating, maxHeight: maxHeight,
                       barWidth: Self.barWidth, spacing: Self.spacing,
                       restingLevels: Self.restingLevels, keyLevels: Self.keyLevels, durations: Self.durations)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveBarsView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.spacing, height: maxHeight)
    }
}

/// Layer-backed bars; positions follow the view's bounds, animations live in the render server.
final class WaveBarsView: NSView {
    private var bars: [CALayer] = []
    private var barWidth: CGFloat = 2.5
    private var spacing: CGFloat = 2.5
    private var maxHeight: CGFloat = 18
    private var signature = ""

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let bar = CALayer()
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(color: CGColor, animating: Bool, maxHeight: CGFloat, barWidth: CGFloat, spacing: CGFloat,
                   restingLevels: [CGFloat], keyLevels: [[CGFloat]], durations: [CFTimeInterval]) {
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = color
            bar.cornerRadius = barWidth / 2
        }
        layoutBars()
        CATransaction.commit()
        // Restart animations only when something that affects them changed.
        let newSignature = "\(animating)-\(maxHeight)"
        guard newSignature != signature else { return }
        signature = newSignature
        let minScale = 3 / max(maxHeight, 3)
        func scale(_ level: CGFloat) -> CGFloat { minScale + (1 - minScale) * level }
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if animating {
                bar.transform = CATransform3DIdentity
                let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
                anim.values = keyLevels[i % keyLevels.count].map(scale)
                anim.duration = durations[i % durations.count]
                anim.repeatCount = .infinity
                anim.calculationMode = .cubic
                anim.isRemovedOnCompletion = false
                bar.add(anim, forKey: "wave")
            } else {
                bar.transform = CATransform3DMakeScale(1, scale(restingLevels[i % restingLevels.count]), 1)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBars()
        CATransaction.commit()
    }

    private func layoutBars() {
        let total = CGFloat(bars.count) * barWidth + CGFloat(max(0, bars.count - 1)) * spacing
        let originX = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: maxHeight)
            bar.position = CGPoint(x: originX + CGFloat(i) * (barWidth + spacing) + barWidth / 2, y: bounds.midY)
        }
    }
}

/// A light tint for the waves taken from the album cover's average colour.
enum PeekAccent {
    static func color(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ns = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        // Keep the hue, but make it bright enough to read on black.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s, 0.55)), brightness: Double(max(b, 0.88)))
    }
}
