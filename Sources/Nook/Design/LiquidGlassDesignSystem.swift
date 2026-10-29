import AppKit
import SwiftUI

/// Visual tokens and building blocks. Uses Liquid Glass (macOS 26+) for interactive controls,
/// and a behind-window blur with a dark gradient for the main surface so text stays readable and
/// the top edge stays pure black where it meets the physical notch.
enum Nook {
    enum Metrics {
        static let openTopRadius: CGFloat = 14
        static let openBottomRadius: CGFloat = 30
        static let closedTopRadius: CGFloat = 6
        static let closedBottomRadius: CGFloat = 11
        static let contentPadding: CGFloat = 16
        static let compactSize = CGSize(width: 660, height: 300)
        static let largeSize = CGSize(width: 820, height: 580)
    }

    enum Palette {
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.62)
        static let tertiaryText = Color.white.opacity(0.42)
        static let hairline = Color.white.opacity(0.09)
        static let fill = Color.white.opacity(0.07)
        static let fillHover = Color.white.opacity(0.13)
        static let accent = Color(red: 0.55, green: 0.78, blue: 1.0)
        static let success = Color(red: 0.45, green: 0.85, blue: 0.55)
        static let warning = Color(red: 1.0, green: 0.78, blue: 0.35)
        static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
        /// Restrained rose glow for the music dock (adapted from the reference's pink/red).
        static let musicGlow = Color(red: 0.96, green: 0.36, blue: 0.5)
    }

    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0.1)
    }

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Notch-style outline: flat top with small outward "ear" flares (like the hardware notch),
/// and generous rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4, rect.height / 2)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Behind-window blur (the only kind that works for a transparent floating panel).
struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// The panel's background: blur + a black gradient that is fully opaque at the top so the
/// surface merges seamlessly with the physical notch.
struct NotchSurface: View {
    var isOpen: Bool
    var transparentWhenClosed: Bool

    var body: some View {
        ZStack {
            if isOpen {
                BehindWindowBlur()
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.1),
                        .init(color: .black.opacity(0.84), location: 0.35),
                        .init(color: .black.opacity(0.78), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                // Closed: solid black, invisible against the notch. On displays without a notch the
                // strip is kept (nearly) invisible but still receives the pointer.
                Color.black.opacity(transparentWhenClosed ? 0.004 : 1)
            }
        }
    }
}

// MARK: Controls (built on the shared dark glass in DarkGlass.swift)

/// Small circular glass icon button with tooltip, accessibility label, hover, pressed and focus states.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(isActive ? Nook.Palette.accent : Nook.Palette.primaryText.opacity(0.9))
        }
        .buttonStyle(GlassDropletButtonStyle(diameter: size, emphasis: .subtle))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Text/label button on a small dark-glass capsule. `prominent` uses a restrained accent tint.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let destructive: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(destructive ? Nook.Palette.danger : Nook.Palette.primaryText)
                .darkGlass(in: Capsule(style: .continuous),
                           tint: prominent ? Nook.Palette.musicGlow.opacity(0.32) : Nook.Glass.tint,
                           highlighted: hovering || configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Small interactive chrome (tab selection etc.): the shared dark glass.
    func nookGlass<S: InsettableShape>(in shape: S) -> some View {
        darkGlass(in: shape)
    }

    /// Content card: rounded-rectangle dark glass.
    func sectionCard() -> some View {
        self
            .padding(10)
            .darkGlass(in: RoundedRectangle(cornerRadius: Nook.Glass.cardRadius, style: .continuous))
    }
}

/// Small status line used by all features.
struct StatusBadge: View {
    enum Tone { case neutral, success, warning, danger, working }
    var text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            if tone == .working {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11)).foregroundStyle(Nook.Palette.secondaryText).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .neutral, .working: return Nook.Palette.tertiaryText
        case .success: return Nook.Palette.success
        case .warning: return Nook.Palette.warning
        case .danger: return Nook.Palette.danger
        }
    }
}
