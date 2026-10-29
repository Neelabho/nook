import Foundation

public enum PlayerState: String, Equatable, Sendable {
    case playing, paused, stopped
}

public struct TrackSnapshot: Equatable, Sendable {
    public var id: String?
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double?
    public var artworkURL: URL?

    public init(id: String?, title: String, artist: String, album: String, durationSeconds: Double?, artworkURL: URL?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }
}

public struct PlayerSnapshot: Equatable, Sendable {
    public var state: PlayerState
    public var track: TrackSnapshot?
    public var positionSeconds: Double?
    public var volume: Int?
    public var shuffling: Bool?
    public var repeating: Bool?

    public init(state: PlayerState, track: TrackSnapshot?, positionSeconds: Double?, volume: Int?, shuffling: Bool?, repeating: Bool?) {
        self.state = state
        self.track = track
        self.positionSeconds = positionSeconds
        self.volume = volume
        self.shuffling = shuffling
        self.repeating = repeating
    }
}

/// Parses the unit-separator-delimited reply of the AppleScript status query used by SpotifyService.
///
/// Field order: state, name, artist, album, duration (ms), position (ms), artwork url, id, volume, shuffling, repeating.
public enum SpotifyStatusParser {
    public static let separator: Character = "\u{1F}"

    public static func parse(_ raw: String) -> PlayerSnapshot? {
        let fields = raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first else { return nil }
        let stateField = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state: PlayerState
        switch stateField {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: return nil
        }
        func field(_ i: Int) -> String? {
            guard i < fields.count else { return nil }
            let v = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty || v == "missing value" ? nil : v
        }
        func number(_ i: Int) -> Double? {
            guard let s = field(i) else { return nil }
            return Double(s.replacingOccurrences(of: ",", with: "."))
        }
        var track: TrackSnapshot?
        if let title = field(1) {
            track = TrackSnapshot(
                id: field(7),
                title: title,
                artist: field(2) ?? "",
                album: field(3) ?? "",
                durationSeconds: number(4).map { $0 / 1000 },
                artworkURL: field(6).flatMap(ArtworkURLPolicy.validated)
            )
        }
        return PlayerSnapshot(
            state: state,
            track: track,
            positionSeconds: number(5).map { $0 / 1000 },
            volume: number(8).map { Int($0.rounded()).clamped(to: 0...100) },
            shuffling: field(9).map { $0 == "true" },
            repeating: field(10).map { $0 == "true" }
        )
    }
}

/// Artwork is only fetched over HTTPS from Spotify's image CDN.
public enum ArtworkURLPolicy {
    public static let allowedHostSuffixes = ["scdn.co", "spotifycdn.com"]

    public static func validated(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let ok = allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        return ok ? url : nil
    }
}

/// Interpolates the playback position locally between infrequent refreshes, so the progress bar
/// moves smoothly without polling Spotify.
public struct PlaybackClock: Equatable, Sendable {
    public var anchorPosition: Double
    public var anchorDate: Date
    public var isPlaying: Bool
    public var duration: Double?

    public init(anchorPosition: Double, anchorDate: Date, isPlaying: Bool, duration: Double?) {
        self.anchorPosition = anchorPosition
        self.anchorDate = anchorDate
        self.isPlaying = isPlaying
        self.duration = duration
    }

    public func position(at date: Date) -> Double {
        var p = anchorPosition
        if isPlaying { p += max(0, date.timeIntervalSince(anchorDate)) }
        if let duration, duration > 0 { p = min(p, duration) }
        return max(0, p)
    }
}

/// Vinyl rotation continuity: where the record should be when the view comes back on screen.
public enum VinylRotation {
    public static let secondsPerTurn = 1.8   // 33⅓ rpm

    /// - Returns: the saved angle if it was paused (or is paused now); otherwise the angle advanced by
    ///   the time spent off screen, as if it had kept turning (clockwise = decreasing radians).
    public static func resumeAngle(saved: Double, savedAt: Date, wasSpinning: Bool, spinningNow: Bool, now: Date) -> Double {
        guard wasSpinning && spinningNow else { return saved }
        let elapsed = max(0, now.timeIntervalSince(savedAt))
        let turns = elapsed / secondsPerTurn
        return saved - (turns - turns.rounded(.down)) * 2 * .pi   // keep the angle small
    }
}

public enum AutomationPermission: Equatable, Sendable {
    case granted, denied, notDetermined, targetNotRunning, unknown
}

/// What the Music feature can do right now, derived from facts about the system.
public struct MusicCapabilities: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case notRunning
        case needsPermission
        case permissionDenied
        case ready
    }

    public var status: Status
    public var canControlPlayback: Bool { status == .ready }
    public var canReadMetadata: Bool { status == .ready }
    public var canSeek: Bool { status == .ready }
    public var canSetVolume: Bool { status == .ready }

    public init(status: Status) { self.status = status }

    public static func evaluate(installed: Bool, running: Bool, permission: AutomationPermission) -> MusicCapabilities {
        guard installed else { return MusicCapabilities(status: .notInstalled) }
        guard running else { return MusicCapabilities(status: .notRunning) }
        switch permission {
        case .granted: return MusicCapabilities(status: .ready)
        case .denied: return MusicCapabilities(status: .permissionDenied)
        case .notDetermined, .unknown: return MusicCapabilities(status: .needsPermission)
        case .targetNotRunning: return MusicCapabilities(status: .notRunning)
        }
    }

    public var explanation: String {
        switch status {
        case .notInstalled: return "Spotify isn't installed."
        case .notRunning: return "Spotify isn't running. Nook won't launch it on its own."
        case .needsPermission: return "Allow Nook to control Spotify to see what's playing."
        case .permissionDenied: return "Nook isn't allowed to control Spotify. Enable it in System Settings › Privacy & Security › Automation."
        case .ready: return "Connected to Spotify."
        }
    }
}
