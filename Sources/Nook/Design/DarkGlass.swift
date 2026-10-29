import AppKit
import NookCore
import SwiftUI

/// Nook's dark Liquid Glass system: one surface treatment and one button style, shared by every
/// section (Music, AI, Shelf, search, settings overlays).
///
/// Rendering follows `GlassAppearance`:
/// - macOS 26+: system Liquid Glass (`glassEffect`) with a charcoal tint. The window server samples
///   and lenses the content *inside Nook's window* behind the glass (genuine refraction by the system).
/// - Older macOS: within-window blur + tint (translucent, no refraction).
/// - Reduce Transparency: solid charcoal.
///
/// Rims, highlights and shading are decorative overlays that never take clicks.
extension Nook {
    enum Glass {
        /// Charcoal tint applied to glass so surfaces read as dark on any background.
        static let tint = Color(white: 0.05).opacity(0.5)
        static let solidFill = Color(white: 0.13)
        static let cardRadius: CGFloat = 14
        static let fieldRadius: CGFloat = 12
        static let tileRadius: CGFloat = 14
        /// Rose/purple reflection used sparingly on the playback droplets.
        static let roseReflection = Color(red: 0.96, green: 0.42, blue: 0.62)
        static let violetReflection = Color(red: 0.62, green: 0.48, blue: 1.0)
    }
}

/// Resolves the glass appearance from the environment's accessibility settings.
private struct ResolvedGlass {
    let look: GlassAppearance
    init(reduceTransparency: Bool, reduceMotion: Bool, contrast: ColorSchemeContrast) {
        look = GlassAppearance.resolve(
            supportsLiquidGlass: Nook.supportsLiquidGlass,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }
}

// MARK: Surface

struct DarkGlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color
    var highlighted: Bool
    var interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let look = ResolvedGlass(reduceTransparency: reduceTransparency, reduceMotion: reduceMotion, contrast: contrast).look
        glass(content, look: look)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    .white.opacity(look.borderOpacity * (highlighted ? 0.75 : 0.5)),
                    .white.opacity(look.borderOpacity * 0.08),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .allowsHitTesting(false)
            }
            .contentShape(shape)
    }

    @ViewBuilder
    private func glass(_ content: Content, look: GlassAppearance) -> some View {
        switch look.mode {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let base = Glass.regular.tint(highlighted ? tint.opacity(0.8) : tint)
                content.glassEffect(interactive ? base.interactive() : base, in: shape)
            } else {
                content.background { fallback(look) }
            }
        case .material, .opaque:
            content.background { fallback(look) }
        }
    }

    @ViewBuilder
    private func fallback(_ look: GlassAppearance) -> some View {
        if look.mode == .opaque {
            shape.fill(Nook.Glass.solidFill)
        } else {
            ZStack {
                BehindWindowBlur(material: .hudWindow, blending: .withinWindow)
                tint
                Color.white.opacity(highlighted ? 0.08 : 0.03)
            }
            .clipShape(shape)
        }
    }
}

extension View {
    /// The shared dark glass surface for cards, fields, tiles, capsules and bubbles.
    func darkGlass<S: InsettableShape>(in shape: S, tint: Color = Nook.Glass.tint, highlighted: Bool = false, interactive: Bool = false) -> some View {
        modifier(DarkGlassSurface(shape: shape, tint: tint, highlighted: highlighted, interactive: interactive))
    }

    /// Text input on dark glass, with an accent rim while focused.
    func glassField(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Nook.Glass.fieldRadius, style: .continuous)
        return self
            .darkGlass(in: shape)
            .overlay(shape.strokeBorder(Nook.Palette.musicGlow.opacity(focused ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
    }
}

// MARK: 3D glass droplet button

/// A small three-dimensional glass droplet: system Liquid Glass in a circle, plus a luminous rim,
/// a specular cap, a soft inner shade along the bottom, a faint rose/violet caustic and a floating
/// shadow. Separate circles; never a shared capsule.
struct GlassDropletButtonStyle: ButtonStyle {
    enum Emphasis { case subtle, standard, primary }
    var diameter: CGFloat
    var emphasis: Emphasis = .standard

    func makeBody(configuration: Configuration) -> some View {
        DropletBody(configuration: configuration, diameter: diameter, emphasis: emphasis)
    }

    private struct DropletBody: View {
        let configuration: Configuration
        let diameter: CGFloat
        let emphasis: Emphasis
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let look = ResolvedGlass(reduceTransparency: reduceTransparency, reduceMotion: reduceMotion, contrast: contrast).look
            let pressed = configuration.isPressed
            let d = diameter
            let caustic = emphasis == .primary ? 0.32 : (emphasis == .standard ? 0.18 : 0.0)

            configuration.label
                .shadow(color: .black.opacity(0.35), radius: 0.8, y: 0.6)
                .frame(width: d, height: d)
                .darkGlass(in: Circle(), tint: Nook.Glass.tint, highlighted: hovering || pressed)
                .overlay {
                    ZStack {
                        if look.showsSpecularHighlight {
                            // Specular cap: light catching the top of the droplet.
                            Ellipse()
                                .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.34 : 0.26), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .frame(width: d * 0.64, height: d * 0.34)
                                .offset(y: -d * 0.21)
                                .blendMode(.plusLighter)
                            // Inner shade along the lower edge gives volume.
                            Circle()
                                .stroke(Color.black.opacity(pressed ? 0.5 : 0.36), lineWidth: d * 0.07)
                                .blur(radius: d * 0.05)
                                .offset(y: d * 0.035)
                                .mask(Circle())
                            if caustic > 0 && !reduceTransparency {
                                // Faint rose/violet caustic where light exits the glass.
                                Circle()
                                    .fill(RadialGradient(colors: [Nook.Glass.roseReflection.opacity(caustic), Nook.Glass.violetReflection.opacity(caustic * 0.4), .clear],
                                                         center: UnitPoint(x: 0.7, y: 0.9), startRadius: 0, endRadius: d * 0.55))
                                    .blendMode(.plusLighter)
                            }
                        }
                        // Delicate luminous rim, brighter top-left.
                        Circle()
                            .strokeBorder(LinearGradient(colors: [
                                .white.opacity(look.borderOpacity * (hovering ? 1.3 : 1.0)),
                                .white.opacity(look.borderOpacity * 0.15),
                                Nook.Glass.roseReflection.opacity(caustic * 0.9),
                            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
                        if isFocused {
                            Circle().strokeBorder(Nook.Palette.accent.opacity(0.85), lineWidth: 1.6).padding(-3)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(emphasis == .subtle ? 0.25 : 0.42), radius: d * 0.16, y: d * 0.1)
                .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : (hovering ? 1.04 : 1)))
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Music backdrop

/// Soft, static wash behind the music content: the album artwork, heavily blurred, clipped to its own
/// frame (never bleeding over the tab header). Drawn once per artwork change; never animates.
struct ArtworkBackdrop: View {
    var artwork: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if let artwork, !reduceTransparency {
                GeometryReader { geo in
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 34, opaque: true)
                        .saturation(1.25)
                        .opacity(0.42)
                }
            }
            LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.2), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
