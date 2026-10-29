import Foundation

/// AppleScript sources sent to Spotify. Kept in NookCore so tests can compile them
/// (a script that fails to compile silently disables the whole Music feature).
///
/// Every script is guarded with `is running`, so Nook never launches Spotify.
/// Only fixed verbs and formatted numbers are ever interpolated; never user text.
public enum SpotifyScripts {
    public static let bundleID = "com.spotify.client"

    /// Reply: state, name, artist, album, duration ms, position ms, artwork url, id, volume,
    /// shuffling, repeating — separated by ASCII 31. Variable names avoid AppleScript reserved
    /// words (`st` is reserved, as in "1st").
    public static let status = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client"
            set fieldSep to (ASCII character 31)
            set playerStateText to (player state as text)
            if playerStateText is "stopped" then return playerStateText
            set currentTrackRef to current track
            set reply to playerStateText
            set reply to reply & fieldSep & my textOf(name of currentTrackRef)
            set reply to reply & fieldSep & my textOf(artist of currentTrackRef)
            set reply to reply & fieldSep & my textOf(album of currentTrackRef)
            set reply to reply & fieldSep & my textOf(duration of currentTrackRef)
            set reply to reply & fieldSep & my textOf((player position * 1000) as integer)
            set reply to reply & fieldSep & my textOf(artwork url of currentTrackRef)
            set reply to reply & fieldSep & my textOf(id of currentTrackRef)
            set reply to reply & fieldSep & my textOf(sound volume)
            set reply to reply & fieldSep & my textOf(shuffling)
            set reply to reply & fieldSep & my textOf(repeating)
            return reply
        end tell
    end if
    return "stopped"
    on textOf(value)
        try
            if value is missing value then return ""
            return value as text
        on error
            return ""
        end try
    end textOf
    """

    public enum Verb: Equatable, Sendable {
        case playPause, next, previous, resume
        case seek(seconds: Double)
        case volume(Int)

        var source: String {
            switch self {
            case .playPause: return "playpause"
            case .resume: return "play"
            case .next: return "next track"
            case .previous: return "previous track"
            case .seek(let seconds):
                return "set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds)))"
            case .volume(let v): return "set sound volume to \(min(max(v, 0), 100))"
            }
        }
    }

    /// `play track "<uri>"` for a validated track, album or artist URI (nil otherwise), so search
    /// results can never inject script text. Spotify's `play track` accepts any of these URIs.
    ///
    /// Note: Spotify's implementation of `in context` was observed to ignore the track and start the
    /// context from its first item, so callers currently don't pass a context for tracks.
    public static func playCommand(uri: String, contextURI: String? = nil) -> String? {
        guard let valid = SpotifyURI.playableURI(uri) else { return nil }
        let isTrack = SpotifyURI.trackURI(valid) != nil
        let context = isTrack ? contextURI.flatMap(SpotifyURI.albumURI).map { " in context \"\($0)\"" } ?? "" : ""
        return """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)" to play track "\(valid)"\(context)
        end if
        """
    }

    /// Track-only variant kept for existing callers/tests.
    public static func playTrackCommand(uri: String, contextURI: String? = nil) -> String? {
        guard SpotifyURI.trackURI(uri) != nil else { return nil }
        return playCommand(uri: uri, contextURI: contextURI)
    }

    public static func command(_ verb: Verb) -> String {
        """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)" to \(verb.source)
        end if
        """
    }
}
