import NookCore
import SwiftUI

/// Spotify search overlay inside the Music panel. Typing only searches; playback starts only from a
/// row's Play button (or Return on a row highlighted with the arrow keys). Escape closes.
struct SpotifySearchView: View {
    @Bindable var model: SpotifySearchModel
    let music: SpotifyService
    let catalog: SpotifyCatalogService
    var onClose: () -> Void
    var openSettings: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            playbackStatus
        }
        .onExitCommand(perform: onClose)
        .task {
            // Focus after the view is installed in the key panel (assigning in onAppear has no effect).
            try? await Task.sleep(for: .milliseconds(120))
            fieldFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spotify search")
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Nook.Palette.secondaryText)
                .accessibilityHidden(true)
            TextField("Songs, artists or albums", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Nook.Palette.primaryText)
                .focused($fieldFocused)
                .onSubmit { model.submit() }
                .onKeyPress(.downArrow) { model.moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveHighlight(by: -1); return .handled }
                .accessibilityLabel("Search Spotify")
                .accessibilityHint("Type a song, artist or album. Use the arrow keys to choose a result and Return to play it.")
            if case .searching = model.phase {
                ProgressView().controlSize(.small).tint(.white).accessibilityLabel("Searching")
            }
            if !model.query.isEmpty {
                Button { model.clear(); fieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Nook.Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Nook.Palette.secondaryText)
            }
            .buttonStyle(GlassDropletButtonStyle(diameter: 22, emphasis: .subtle))
            .help("Close search (Esc)")
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .glassField(focused: fieldFocused)
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            hint
        case .needsSetup(let message):
            VStack(alignment: .leading, spacing: 8) {
                StatusBadge(text: message, tone: .warning)
                HStack(spacing: 6) {
                    Button { openInSpotifyApp() } label: { Label("Open this search in the Spotify app", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || !music.isInstalled)
                        .help("Fallback: opens Spotify's own search for this text. These are not in-Nook results, and nothing plays until you choose a track in Spotify.")
                    Button("Set Up In-Nook Search…", action: openSettings).buttonStyle(PillButtonStyle())
                }
                Text("In-Nook catalogue results need Spotify's Web API (a one-time setup). Spotify's app scripting can't search.")
                    .font(.system(size: 10.5)).foregroundStyle(Nook.Palette.tertiaryText)
            }
        case .searching:
            if model.results.isEmpty {
                StatusBadge(text: "Searching Spotify…", tone: .working)
            } else {
                resultsList.opacity(0.6)
            }
        case .results:
            resultsList
        case .noResults(let query):
            StatusBadge(text: "Nothing found for “\(query)”.", tone: .neutral)
        case .failed(let message):
            HStack(spacing: 8) {
                StatusBadge(text: message, tone: .danger)
                Button("Retry") { model.submit() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Search songs, artists or albums. Press ▶ to play a result in Spotify.")
                .font(.system(size: 11.5)).foregroundStyle(Nook.Palette.secondaryText)
            Text(catalog.configurationProblem() == nil
                 ? "Results come from Spotify's full catalogue. Your search text is sent to Spotify."
                 : "In-Nook results aren't set up yet; you can still open the search in the Spotify app.")
                .font(.system(size: 10.5)).foregroundStyle(Nook.Palette.tertiaryText)
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(SpotifyCatalogItem.Kind.allCases, id: \.self) { kind in
                        let section = model.results.enumerated().filter { $0.element.kind == kind }
                        if !section.isEmpty {
                            Text(sectionTitle(kind))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Nook.Palette.tertiaryText)
                                .textCase(.uppercase)
                                .padding(.horizontal, 8).padding(.top, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section, id: \.element.id) { index, item in
                                SearchResultRow(item: item, highlighted: model.highlightedIndex == index,
                                                state: model.playback, music: music) { model.play(item) }
                                    .id(item.id)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.highlightedIndex) { _, index in
                if let index, model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
            }
        }
        .accessibilityLabel("\(model.results.count) results")
    }

    private func sectionTitle(_ kind: SpotifyCatalogItem.Kind) -> String {
        switch kind {
        case .track: return "Songs"
        case .artist: return "Artists"
        case .album: return "Albums"
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if let note = catalog.playbackNote, case .started = model.playback {
            StatusBadge(text: note, tone: .warning)
        }
        if case .failed(_, let message) = model.playback {
            HStack(spacing: 8) {
                StatusBadge(text: message, tone: .danger)
                if !music.isRunning && music.isInstalled {
                    Button("Open Spotify") { music.openSpotify() }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func openInSpotifyApp() {
        guard let url = SpotifySearchLinks.appSearchURL(for: model.query) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SearchResultRow: View {
    let item: SpotifyCatalogItem
    let highlighted: Bool
    let state: PlaybackRequestState
    let music: SpotifyService
    let play: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var isStarting: Bool { state == .starting(trackID: item.id) }
    private var isPlayingThis: Bool {
        item.kind == .track && state == .started(trackID: item.id) && music.snapshot?.track?.id == item.uri
    }

    private var playLabel: String {
        switch item.kind {
        case .track: return "Play \(item.title) by \(item.artistLine)"
        case .album: return "Play the album \(item.title)"
        case .artist: return "Play \(item.title)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 32, height: 32)
                .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Nook.Palette.primaryText).lineLimit(1)
                    if item.explicit {
                        Text("E").font(.system(size: 8, weight: .bold)).foregroundStyle(Nook.Palette.primaryText)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.25)))
                            .accessibilityLabel("Explicit")
                    }
                }
                Text(item.subtitle).font(.system(size: 10.5)).foregroundStyle(Nook.Palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let ms = item.durationMs {
                Text(MusicView.time(Double(ms) / 1000)).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Nook.Palette.tertiaryText).accessibilityHidden(true)
            }
            Button(action: play) {
                Group {
                    if isStarting {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: isPlayingThis ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Nook.Palette.primaryText)
                    }
                }
            }
            .buttonStyle(GlassDropletButtonStyle(diameter: 26, emphasis: item.isPlayable ? .standard : .subtle))
            .disabled(!item.isPlayable || isStarting)
            .help(item.isPlayable ? playLabel : "Not available in your region")
            .accessibilityLabel(item.isPlayable ? playLabel : "\(item.title) is unavailable")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if highlighted || hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Nook.Palette.musicGlow.opacity(0.16) : Color.white.opacity(0.05))
            }
        }
        .opacity(item.isPlayable ? 1 : 0.5)
        .onHover { hovering = $0 }
        .task(id: item.artworkURL) {
            guard let url = item.artworkURL else { return }
            thumbnail = music.cachedImage(for: url)
            if thumbnail == nil { thumbnail = await music.image(for: url) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: item.kind == .artist ? "person.fill" : (item.kind == .album ? "square.stack.fill" : "music.note"))
                .font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.06))
        }
    }
}
