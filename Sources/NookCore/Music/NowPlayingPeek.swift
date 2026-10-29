import Foundation

/// Decides when the closed notch shows the "now playing" peek (album art on the left wing,
/// animated waves on the right).
///
/// The peek appears only while music is playing and the panel is closed, and only for
/// `lingerSeconds` after one of these moments: the panel closes, playback starts or resumes, or the
/// track changes. Pausing or stopping hides it at once. Turning the setting off hides it.
public struct NowPlayingPeek: Equatable, Sendable {
    public static let lingerSeconds: TimeInterval = 120

    public enum Event: Equatable, Sendable {
        case panelClosed
        case playbackStarted
        case trackChanged
        case playbackStopped
        case disabled
    }

    /// When the current peek ends; nil when there is none.
    public private(set) var shownUntil: Date?

    public init() {}

    public mutating func handle(_ event: Event, isPlaying: Bool, enabled: Bool, now: Date) {
        switch event {
        case .panelClosed, .playbackStarted, .trackChanged:
            shownUntil = enabled && isPlaying ? now.addingTimeInterval(Self.lingerSeconds) : nil
        case .playbackStopped, .disabled:
            shownUntil = nil
        }
    }

    public func isVisible(now: Date, panelOpen: Bool, isPlaying: Bool, enabled: Bool) -> Bool {
        guard enabled, isPlaying, !panelOpen, let shownUntil else { return false }
        return now < shownUntil
    }

    /// Maps a snapshot change to the peek event it implies, if any.
    public static func event(from old: PlayerSnapshot?, to new: PlayerSnapshot?) -> Event? {
        let wasPlaying = old?.state == .playing
        let isPlaying = new?.state == .playing
        if wasPlaying && !isPlaying { return .playbackStopped }
        if !wasPlaying && isPlaying { return .playbackStarted }
        if isPlaying, let id = new?.track?.id, id != old?.track?.id { return .trackChanged }
        return nil
    }
}
