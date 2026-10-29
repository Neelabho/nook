import Foundation
import Testing
@testable import NookCore

@Suite("Spotify integration logic")
struct MusicTests {
    let sep = String(SpotifyStatusParser.separator)

    @Test func parsesPlayingStatus() throws {
        let raw = ["playing", "Paranoid Android", "Radiohead", "OK Computer", "386000", "61234",
                   "https://i.scdn.co/image/ab67616d0000b273abc", "spotify:track:6LgJvl0Xdtc73RJ1mmpotq", "64", "false", "true"].joined(separator: sep)
        let snap = try #require(SpotifyStatusParser.parse(raw))
        #expect(snap.state == .playing)
        #expect(snap.track?.title == "Paranoid Android")
        #expect(snap.track?.durationSeconds == 386)
        #expect(snap.positionSeconds == 61.234)
        #expect(snap.track?.artworkURL?.host == "i.scdn.co")
        #expect(snap.volume == 64)
        #expect(snap.shuffling == false)
        #expect(snap.repeating == true)
    }

    @Test func toleratesMissingValuesAndCommaDecimals() throws {
        let raw = ["paused", "Song", "missing value", "", "200000", "12,5", "", "", "", "", ""].joined(separator: sep)
        let snap = try #require(SpotifyStatusParser.parse(raw))
        #expect(snap.state == .paused)
        #expect(snap.track?.artist == "")
        #expect(snap.positionSeconds == 0.0125)
        #expect(snap.track?.artworkURL == nil)
        #expect(snap.volume == nil)
    }

    @Test func stoppedWithoutTrack() throws {
        let snap = try #require(SpotifyStatusParser.parse("stopped"))
        #expect(snap.state == .stopped)
        #expect(snap.track == nil)
        #expect(SpotifyStatusParser.parse("") == nil)
        #expect(SpotifyStatusParser.parse("garbage") == nil)
    }

    @Test func artworkIsRestrictedToSpotifyCDNOverHTTPS() {
        #expect(ArtworkURLPolicy.validated("https://i.scdn.co/image/x") != nil)
        #expect(ArtworkURLPolicy.validated("https://image-cdn-ak.spotifycdn.com/image/x") != nil)
        #expect(ArtworkURLPolicy.validated("http://i.scdn.co/image/x") == nil)
        #expect(ArtworkURLPolicy.validated("https://evil.example.com/scdn.co") == nil)
        #expect(ArtworkURLPolicy.validated("https://notscdn.co/x") == nil)
        #expect(ArtworkURLPolicy.validated("file:///etc/passwd") == nil)
    }

    @Test func playbackClockInterpolatesAndClamps() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let playing = PlaybackClock(anchorPosition: 10, anchorDate: t0, isPlaying: true, duration: 12)
        #expect(playing.position(at: t0.addingTimeInterval(1)) == 11)
        #expect(playing.position(at: t0.addingTimeInterval(100)) == 12)
        let paused = PlaybackClock(anchorPosition: 10, anchorDate: t0, isPlaying: false, duration: 12)
        #expect(paused.position(at: t0.addingTimeInterval(5)) == 10)
    }

    @Test func vinylResumesWhereItLeftOff() {
        let t0 = Date(timeIntervalSince1970: 1000)
        // Paused: exactly the saved angle, no jump.
        #expect(VinylRotation.resumeAngle(saved: -1.0, savedAt: t0, wasSpinning: false, spinningNow: true, now: t0.addingTimeInterval(30)) == -1.0)
        #expect(VinylRotation.resumeAngle(saved: -1.0, savedAt: t0, wasSpinning: true, spinningNow: false, now: t0.addingTimeInterval(30)) == -1.0)
        // Kept playing while hidden: advanced by elapsed time (half a turn after 0.9 s).
        let half = VinylRotation.resumeAngle(saved: 0, savedAt: t0, wasSpinning: true, spinningNow: true, now: t0.addingTimeInterval(0.9))
        #expect(abs(half - (-Double.pi)) < 1e-6)
        // Whole turns are dropped so the angle stays small.
        let many = VinylRotation.resumeAngle(saved: 0, savedAt: t0, wasSpinning: true, spinningNow: true, now: t0.addingTimeInterval(1.8 * 1000 + 0.45))
        #expect(abs(many - (-Double.pi / 2)) < 1e-6)
    }

    @Test func capabilityDetection() {
        #expect(MusicCapabilities.evaluate(installed: false, running: false, permission: .unknown).status == .notInstalled)
        #expect(MusicCapabilities.evaluate(installed: true, running: false, permission: .granted).status == .notRunning)
        #expect(MusicCapabilities.evaluate(installed: true, running: true, permission: .notDetermined).status == .needsPermission)
        #expect(MusicCapabilities.evaluate(installed: true, running: true, permission: .denied).status == .permissionDenied)
        let ready = MusicCapabilities.evaluate(installed: true, running: true, permission: .granted)
        #expect(ready.status == .ready && ready.canControlPlayback && ready.canReadMetadata)
        #expect(!MusicCapabilities(status: .permissionDenied).canControlPlayback)
    }

    // MARK: Closed-notch now-playing peek

    private func snap(_ state: PlayerState, _ id: String?) -> PlayerSnapshot {
        PlayerSnapshot(state: state, track: id.map { TrackSnapshot(id: $0, title: $0, artist: "", album: "", durationSeconds: nil, artworkURL: nil) },
                       positionSeconds: nil, volume: nil, shuffling: nil, repeating: nil)
    }

    @Test func peekShowsForTwoMinutesAfterTheNotchCloses() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var peek = NowPlayingPeek()
        peek.handle(.panelClosed, isPlaying: true, enabled: true, now: t0)
        #expect(peek.isVisible(now: t0.addingTimeInterval(1), panelOpen: false, isPlaying: true, enabled: true))
        #expect(peek.isVisible(now: t0.addingTimeInterval(119), panelOpen: false, isPlaying: true, enabled: true))
        #expect(!peek.isVisible(now: t0.addingTimeInterval(120), panelOpen: false, isPlaying: true, enabled: true), "gone after 2 minutes")
        #expect(!peek.isVisible(now: t0.addingTimeInterval(5), panelOpen: true, isPlaying: true, enabled: true), "never while the panel is open")
    }

    @Test func peekNeedsPlaybackAndTheSetting() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var peek = NowPlayingPeek()
        peek.handle(.panelClosed, isPlaying: false, enabled: true, now: t0)
        #expect(peek.shownUntil == nil, "nothing playing → no peek")
        peek.handle(.panelClosed, isPlaying: true, enabled: false, now: t0)
        #expect(peek.shownUntil == nil, "setting off → no peek")
        peek.handle(.panelClosed, isPlaying: true, enabled: true, now: t0)
        #expect(!peek.isVisible(now: t0, panelOpen: false, isPlaying: false, enabled: true), "pausing hides it")
        #expect(!peek.isVisible(now: t0, panelOpen: false, isPlaying: true, enabled: false), "turning it off hides it")
        peek.handle(.playbackStopped, isPlaying: false, enabled: true, now: t0)
        #expect(peek.shownUntil == nil)
    }

    @Test func peekRestartsOnResumeAndTrackChange() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var peek = NowPlayingPeek()
        peek.handle(.panelClosed, isPlaying: true, enabled: true, now: t0)
        peek.handle(.trackChanged, isPlaying: true, enabled: true, now: t0.addingTimeInterval(100))
        #expect(peek.isVisible(now: t0.addingTimeInterval(200), panelOpen: false, isPlaying: true, enabled: true))
        #expect(NowPlayingPeek.event(from: snap(.paused, "a"), to: snap(.playing, "a")) == .playbackStarted)
        #expect(NowPlayingPeek.event(from: snap(.playing, "a"), to: snap(.paused, "a")) == .playbackStopped)
        #expect(NowPlayingPeek.event(from: snap(.playing, "a"), to: snap(.playing, "b")) == .trackChanged)
        #expect(NowPlayingPeek.event(from: snap(.playing, "a"), to: nil) == .playbackStopped, "Spotify quit")
        #expect(NowPlayingPeek.event(from: snap(.playing, "a"), to: snap(.playing, "a")) == nil)
        #expect(NowPlayingPeek.event(from: snap(.paused, "a"), to: snap(.paused, "b")) == nil)
    }

    @Test func peekSettingDefaultsOnAndSurvivesOldSettings() throws {
        #expect(NookSettings().nowPlayingPeek)
        let old = Data(#"{"vinylAnimation":false}"#.utf8)
        #expect(NookSettings.decode(old).nowPlayingPeek, "settings saved before this feature turn it on")
        var off = NookSettings(); off.nowPlayingPeek = false
        #expect(NookSettings.decode(off.encoded()).nowPlayingPeek == false)
    }
}
