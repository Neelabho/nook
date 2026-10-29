import NookCore
import SwiftUI

/// Music panel: artwork + animated vinyl, track info, progress, three glass playback droplets, and a
/// single search icon in the top-right corner. No dock, no duplicate metadata, no volume control.
struct MusicView: View {
    let music: SpotifyService
    let settings: SettingsService
    let search: SpotifySearchModel
    let catalog: SpotifyCatalogService
    /// Makes the (non-activating) panel key so the search field can receive typing.
    /// Called only from the user's own click on the search icon.
    var requestKeyboardFocus: () -> Void = {}
    var openMusicSettings: () -> Void = {}

    @State private var scrubbing: Double?
    @State private var searching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsSearchIcon && !searching {
                SearchIconButton { openSearch() }
                    .padding(.top, 2)
                    .transition(.opacity)
            }
            if searching {
                SpotifySearchView(model: search, music: music, catalog: catalog, onClose: closeSearch, openSettings: openMusicSettings)
                    .padding(10)
                    .darkGlass(in: RoundedRectangle(cornerRadius: Nook.Glass.cardRadius + 4, style: .continuous))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                    .zIndex(1)
            }
        }
        .background {
            if music.capabilities.status == .ready, music.snapshot?.track != nil {
                ArtworkBackdrop(artwork: music.artwork)
                    .padding(.horizontal, -(Nook.Metrics.contentPadding + 6))
                    .padding(.bottom, -Nook.Metrics.contentPadding)
                    .animation(.easeInOut(duration: 0.4), value: music.artwork)
            }
        }
    }

    private var showsSearchIcon: Bool {
        settings.settings.musicEnabled && music.capabilities.status == .ready
    }

    @ViewBuilder
    private var content: some View {
        if !settings.settings.musicEnabled {
            unavailable(text: "Music controls are turned off in Settings.", tone: .neutral) { EmptyView() }
        } else {
            switch music.capabilities.status {
            case .ready:
                if let snapshot = music.snapshot, let track = snapshot.track {
                    player(snapshot: snapshot, track: track)
                } else {
                    unavailable(text: "Spotify is open, but nothing is playing.", tone: .neutral) {
                        Button("Play") { music.playPause() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                }
            case .notInstalled:
                unavailable(text: music.capabilities.explanation, tone: .neutral) { EmptyView() }
            case .notRunning:
                unavailable(text: music.capabilities.explanation, tone: .neutral) {
                    Button("Open Spotify") { music.openSpotify() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            case .needsPermission:
                unavailable(text: "Nook needs your permission to control Spotify. macOS will ask once.", tone: .warning) {
                    Button(music.isBusy ? "Waiting…" : "Connect to Spotify") { music.connect() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(music.isBusy)
                }
            case .permissionDenied:
                unavailable(text: music.capabilities.explanation, tone: .danger) {
                    Button("Open Automation Settings") { music.openAutomationSettings() }.buttonStyle(PillButtonStyle())
                    Button("Check Again") { music.connect() }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    // MARK: Search open/close

    private func openSearch() {
        requestKeyboardFocus()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.88)) { searching = true }
    }

    private func closeSearch() {
        search.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.88)) { searching = false }
    }

    // MARK: States

    private func unavailable<Actions: View>(text: String, tone: StatusBadge.Tone, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 24) {
            VinylView(label: nil, spinning: false, diameter: 116)
                .frame(width: 116, height: 116)
                .opacity(0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                StatusBadge(text: text, tone: tone)
                HStack { actions() }
                if let error = music.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Player

    private func player(snapshot: PlayerSnapshot, track: TrackSnapshot) -> some View {
        let playing = snapshot.state == .playing
        // Spin follows Spotify's real state (and Reduce Motion / the user's preference).
        let spin = playing && settings.settings.vinylAnimation && !settings.effectiveReduceMotion
        return HStack(alignment: .center, spacing: 26) {
            ZStack(alignment: .leading) {
                VinylView(label: music.artwork, spinning: spin, diameter: 124)
                    .frame(width: 124, height: 124)
                    .offset(x: playing ? 58 : 40)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: playing)
                    .accessibilityHidden(true)
                cover
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 4, y: 6)
            }
            .frame(width: 196, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Nook.Palette.primaryText)
                        .lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 12))
                        .foregroundStyle(Nook.Palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.trailing, 36)            // keep clear of the search icon
                .accessibilityElement(children: .combine)
                .animation(nil, value: track.id)   // swap metadata without flicker

                progress(snapshot: snapshot, track: track)
                controls(playing: playing)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// Three separate glass droplets; Play/Pause is slightly larger.
    private func controls(playing: Bool) -> some View {
        GlassContainerIfAvailable(spacing: 18) {
            HStack(spacing: 18) {
                Button { music.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Nook.Palette.primaryText)
                }
                .buttonStyle(GlassDropletButtonStyle(diameter: 40))
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous track (⌘←)")
                .accessibilityLabel("Previous track")

                Button { music.playPause() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Nook.Palette.primaryText)
                        .offset(x: playing ? 0 : 1.5)   // optical centring of the play triangle
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(GlassDropletButtonStyle(diameter: 52, emphasis: .primary))
                .keyboardShortcut(searching ? nil : KeyboardShortcut(.space, modifiers: []))
                .help(playing ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(playing ? "Pause" : "Play")

                Button { music.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Nook.Palette.primaryText)
                }
                .buttonStyle(GlassDropletButtonStyle(diameter: 40))
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next track (⌘→)")
                .accessibilityLabel("Next track")
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork = music.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                .accessibilityLabel("Album artwork")
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(Nook.Palette.tertiaryText)
            }
            .accessibilityLabel(settings.settings.loadArtwork ? "Artwork loading" : "Artwork disabled")
        }
    }

    private func progress(snapshot: PlayerSnapshot, track: TrackSnapshot) -> some View {
        let duration = track.durationSeconds ?? 0
        // Ticks once per second only while playing and visible.
        return TimelineView(.periodic(from: .now, by: snapshot.state == .playing ? 1 : 3600)) { context in
            let position = scrubbing ?? music.clock?.position(at: context.date) ?? 0
            VStack(spacing: 3) {
                Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...max(duration, 1)) { editing in
                    if !editing, let target = scrubbing {
                        music.seek(to: target)
                        scrubbing = nil
                    }
                }
                .controlSize(.mini)
                .tint(Nook.Palette.musicGlow)
                .disabled(duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.time(position)) of \(Self.time(duration))")
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text("-" + Self.time(max(0, duration - position)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Nook.Palette.tertiaryText)
                .accessibilityHidden(true)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Groups nearby glass shapes for the system (better blending and performance) on macOS 26+.
struct GlassContainerIfAvailable<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// The Music panel's only top-right element: an understated magnifying glass that brightens on hover.
struct SearchIconButton: View {
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.5))
                .frame(width: 28, height: 28)
                .background {
                    if hovering { Circle().fill(Color.white.opacity(0.001)).darkGlass(in: Circle(), highlighted: true) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = h } }
        .keyboardShortcut("f", modifiers: .command)
        .help("Search Spotify (⌘F)")
        .accessibilityLabel("Search Spotify")
    }
}
