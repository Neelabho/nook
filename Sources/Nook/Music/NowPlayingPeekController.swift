import Foundation
import NookCore
import Observation

/// Drives the closed-notch "now playing" peek from panel open/close and Spotify events.
///
/// Event-driven, no polling: one sleeping task ends the peek after `NowPlayingPeek.lingerSeconds`.
@MainActor
@Observable
final class NowPlayingPeekController {
    private(set) var isVisible = false

    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private let music: SpotifyService
    @ObservationIgnored private var peek = NowPlayingPeek()
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Called when `isVisible` changes, so the window can resize.
    @ObservationIgnored var onVisibilityChange: (Bool) -> Void = { _ in }

    init(settings: SettingsService, music: SpotifyService) {
        self.settings = settings
        self.music = music
    }

    private var enabled: Bool { settings.settings.nowPlayingPeek && settings.settings.musicEnabled }
    private var isPlaying: Bool { music.snapshot?.state == .playing }

    func start() {
        music.wantsArtworkWhileHidden = enabled
        music.onSnapshotChange = { [weak self] old, new in
            guard let self, let event = NowPlayingPeek.event(from: old, to: new) else { return }
            self.send(event)
        }
    }

    func panelDidOpen() {
        panelOpen = true
        update()
    }

    func panelDidClose() {
        panelOpen = false
        send(.panelClosed)
    }

    func settingsChanged() {
        music.wantsArtworkWhileHidden = enabled
        if !enabled { send(.disabled) } else { update() }
    }

    private func send(_ event: NowPlayingPeek.Event) {
        // While the panel is open the Music view shows everything; a peek starts when it closes.
        if panelOpen, event != .playbackStopped, event != .disabled { return }
        peek.handle(event, isPlaying: isPlaying, enabled: enabled, now: Date())
        update()
    }

    private func update() {
        let visible = peek.isVisible(now: Date(), panelOpen: panelOpen, isPlaying: isPlaying, enabled: enabled)
        expiryTask?.cancel()
        expiryTask = nil
        if visible, let until = peek.shownUntil {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange(visible)
    }

    var debugState: [String: Any] {
        ["peekVisible": isVisible, "peekSecondsLeft": peek.shownUntil.map { max(0, Int($0.timeIntervalSinceNow)) } ?? -1]
    }
}
