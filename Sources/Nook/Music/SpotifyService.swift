import AppKit
import Carbon
import NookCore
import Observation

/// Local Spotify integration via its documented AppleScript dictionary plus the
/// `com.spotify.client.PlaybackStateChanged` distributed notification.
///
/// - Never launches Spotify: every script is guarded by "is running" and a running-app check.
/// - Event-driven: metadata refreshes when Spotify posts a state change, or when the Music view
///   appears. While the Music view is visible and playing, position is re-synced at a slow, adjustable
///   interval and interpolated locally in between. Nothing runs while the panel is closed.
/// - Requires the user's one-time Automation consent ("Nook wants to control Spotify"), requested
///   only when the user clicks Connect.
@MainActor
@Observable
final class SpotifyService {
    nonisolated static let bundleID = "com.spotify.client"

    private(set) var capabilities = MusicCapabilities(status: .notRunning)
    private(set) var snapshot: PlayerSnapshot?
    private(set) var clock: PlaybackClock?
    private(set) var artwork: NSImage?
    private(set) var lastError: String?
    private(set) var isBusy = false

    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private let diagnostics: DiagnosticsService
    @ObservationIgnored private let runner = AppleScriptRunner()
    /// Automation consent is tracked from the result of real Apple Events rather than
    /// `AEDeterminePermissionToAutomateTarget`, which was observed to block indefinitely on
    /// macOS 26.5 (inside TCC) even with `askUserIfNeeded == false`.
    @ObservationIgnored private var permission: AutomationPermission =
        UserDefaults.standard.bool(forKey: SpotifyService.authorizedKey) ? .granted : .notDetermined
    static let authorizedKey = "music.spotifyAuthorized"
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var visible = false
    /// Called with the previous and new snapshot whenever playback state or the track changes.
    @ObservationIgnored var onSnapshotChange: ((PlayerSnapshot?, PlayerSnapshot?) -> Void)?
    /// Set while the closed-notch peek may show: a track change seen while the panel is closed then
    /// triggers one status read (one Apple Event) so the new song's artwork URL is known.
    @ObservationIgnored var wantsArtworkWhileHidden = false
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    /// Shared by now-playing artwork and search-result thumbnails; bounded, and in-flight
    /// downloads are de-duplicated so the same image is never fetched twice concurrently.
    @ObservationIgnored private var imageCache = BoundedCache<URL, NSImage>(capacity: 64)
    @ObservationIgnored private var imageLoads: [URL: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private lazy var artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(settings: SettingsService, diagnostics: DiagnosticsService) {
        self.settings = settings
        self.diagnostics = diagnostics
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    // MARK: Lifecycle

    func start() {
        guard settings.settings.musicEnabled, observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            self?.reevaluate(refresh: true)
        }
        observe(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            let old = self?.snapshot
            self?.snapshot = nil
            self?.clock = nil
            self?.onSnapshotChange?(old, nil)
            self?.reevaluate(refresh: false)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.spotify.client.PlaybackStateChanged")) { [weak self] note in
            self?.playbackStateChanged(note)
        }
        reevaluate(refresh: false)
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        resyncTask?.cancel()
        artworkTask?.cancel()
    }

    private static func isSpotify(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            // Delivered on the main queue; Notification isn't Sendable, so hand it over explicitly.
            nonisolated(unsafe) let delivered = note
            MainActor.assumeIsolated { handler(delivered) }
        }
        observers.append((center, token))
    }

    /// Called when the Music view appears/disappears.
    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        visible = isVisible
        if isVisible {
            reevaluate(refresh: true)
        } else {
            resyncTask?.cancel()
            resyncTask = nil
        }
    }

    // MARK: Capability detection

    private func reevaluate(refresh: Bool) {
        let running = isRunning
        Task {
            capabilities = MusicCapabilities.evaluate(installed: isInstalled, running: running, permission: running ? permission : .targetNotRunning)
            if refresh && capabilities.status == .ready && visible { await self.refresh() }
            scheduleResync()
        }
    }

    /// User-initiated: sends the first real Apple Event, which makes macOS show its one-time
    /// "Nook wants to control Spotify" prompt if consent hasn't been decided yet.
    func connect() {
        guard isRunning else {
            lastError = "Open Spotify first; Nook won't launch it for you."
            return
        }
        isBusy = true
        lastError = nil
        Task {
            defer { isBusy = false }
            do {
                let raw = try await runner.run(AppleScriptRunner.statusScript)
                setAuthorized(true)
                capabilities = MusicCapabilities.evaluate(installed: isInstalled, running: isRunning, permission: .granted)
                if let snap = SpotifyStatusParser.parse(raw) { apply(snap) }
                diagnostics.record("music", "Connected to Spotify")
            } catch let error as AppleScriptRunner.ScriptError {
                handle(error)
                diagnostics.record("music", "Connect failed: \(error)")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func setAuthorized(_ authorized: Bool) {
        permission = authorized ? .granted : .denied
        UserDefaults.standard.set(authorized, forKey: Self.authorizedKey)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Events

    private func playbackStateChanged(_ note: Notification) {
        // Cheap path from the notification's own payload (no Apple Event); full refresh only when visible.
        if let info = note.userInfo, let stateText = (info["Player State"] as? String)?.lowercased(),
           let state = PlayerState(rawValue: stateText) {
            var snap = snapshot ?? PlayerSnapshot(state: state, track: nil, positionSeconds: nil, volume: nil, shuffling: nil, repeating: nil)
            snap.state = state
            if let name = info["Name"] as? String {
                let trackID = info["Track ID"] as? String
                let sameTrack = trackID != nil && trackID == snap.track?.id
                snap.track = TrackSnapshot(
                    id: trackID, title: name, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                    durationSeconds: (info["Duration"] as? NSNumber).map { $0.doubleValue / 1000 },
                    artworkURL: sameTrack ? snap.track?.artworkURL : nil
                )
            }
            if let position = info["Playback Position"] as? NSNumber { snap.positionSeconds = position.doubleValue }
            apply(snap)
        }
        if visible && capabilities.status == .ready {
            Task { await refresh() }
        } else if wantsArtworkWhileHidden, capabilities.status == .ready, snapshot?.state == .playing,
                  snapshot?.track != nil, snapshot?.track?.artworkURL == nil {
            Task { await refresh() }
        } else if capabilities.status != .ready {
            reevaluate(refresh: false)
        }
    }

    private func scheduleResync() {
        resyncTask?.cancel()
        guard visible, capabilities.status == .ready, snapshot?.state == .playing else { return }
        let interval = settings.settings.progressRefreshSeconds
        resyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.visible else { return }
                await self.refresh()
            }
        }
    }

    // MARK: Queries & commands

    func refresh() async {
        guard isRunning else { reevaluate(refresh: false); return }
        do {
            let raw = try await runner.run(AppleScriptRunner.statusScript)
            guard let snap = SpotifyStatusParser.parse(raw) else { return }
            lastError = nil
            apply(snap)
        } catch let error as AppleScriptRunner.ScriptError {
            handle(error)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ snap: PlayerSnapshot) {
        let trackChanged = snap.track?.id != snapshot?.track?.id || snap.track?.artworkURL != snapshot?.track?.artworkURL
        let old = snapshot
        snapshot = snap
        clock = snap.positionSeconds.map {
            PlaybackClock(anchorPosition: $0, anchorDate: Date(), isPlaying: snap.state == .playing, duration: snap.track?.durationSeconds)
        }
        if trackChanged { loadArtwork(snap.track?.artworkURL) }
        if visible { scheduleResync() }
        if old?.state != snap.state || old?.track?.id != snap.track?.id { onSnapshotChange?(old, snap) }
    }

    private func handle(_ error: AppleScriptRunner.ScriptError) {
        switch error {
        case .notPermitted:
            setAuthorized(false)
            capabilities = MusicCapabilities(status: .permissionDenied)
        case .needsConsent:
            permission = .notDetermined
            capabilities = MusicCapabilities(status: .needsPermission)
        case .notRunning:
            capabilities = MusicCapabilities(status: .notRunning)
        case .failed(let message):
            lastError = message
            diagnostics.record("music", "Script failed: \(message)")
        }
    }

    func playPause() { command(.playPause) }
    func next() { command(.next) }
    func previous() { command(.previous) }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        command(.seek(seconds: seconds))
    }

    func setVolume(_ volume: Int) {
        command(.volume(volume), refreshAfter: false)
        if var snap = snapshot { snap.volume = volume; snapshot = snap }
    }

    /// Commands are fixed strings or formatted numbers: user text is never interpolated into scripts.
    private func command(_ verb: SpotifyScripts.Verb, refreshAfter: Bool = true) {
        guard capabilities.canControlPlayback else { return }
        Task {
            do {
                let trackBefore = snapshot?.track?.id
                _ = try await runner.run(SpotifyScripts.command(verb))
                if refreshAfter {
                    try? await Task.sleep(for: .milliseconds(150))
                    await refresh()
                    // Spotify can take longer to switch tracks (observed near the end of a track);
                    // re-check a few times rather than showing stale metadata.
                    if verb == .next || verb == .previous {
                        for delay in [350, 700, 1200] where snapshot?.track?.id == trackBefore {
                            try? await Task.sleep(for: .milliseconds(delay))
                            await refresh()
                        }
                    }
                }
            } catch let error as AppleScriptRunner.ScriptError {
                handle(error)
            } catch {}
        }
    }

    // MARK: Playing a specific track (search results)

    struct PlaybackError: LocalizedError {
        var errorDescription: String?
    }

    /// Plays a catalogue track, album or artist in the Spotify app. Only validated URIs reach AppleScript.
    /// Tracks play within their album when the album is known, so Spotify's own queue, repeat and
    /// shuffle settings apply afterwards. Nook never changes repeat/shuffle.
    func playTrack(uri: String, albumContext: String? = nil) async throws {
        // Spotify's AppleScript `play track X in context <album>` ignores X and starts the album at
        // track 1 (verified live). Playing the wrong song
        // is worse than a single-track context, so the context is not passed until a supported way to
        // start a track *within* its album is in place (Web API playback with an offset).
        _ = albumContext
        guard let source = SpotifyScripts.playCommand(uri: uri, contextURI: nil) else { throw PlaybackError(errorDescription: "That isn't a playable Spotify item.") }
        guard isRunning else { throw PlaybackError(errorDescription: "Spotify isn't running. Open Spotify, then try again.") }
        guard capabilities.canControlPlayback else {
            throw PlaybackError(errorDescription: capabilities.status == .permissionDenied
                ? "Nook isn't allowed to control Spotify (System Settings › Privacy & Security › Automation)."
                : "Connect Nook to Spotify first (Music tab › Connect).")
        }
        do {
            _ = try await runner.run(source)
        } catch let error as AppleScriptRunner.ScriptError {
            handle(error)
            switch error {
            case .notPermitted: throw PlaybackError(errorDescription: "Nook isn't allowed to control Spotify.")
            case .notRunning: throw PlaybackError(errorDescription: "Spotify quit. Open it and try again.")
            case .needsConsent: throw PlaybackError(errorDescription: "Connect Nook to Spotify first.")
            case .failed(let message): throw PlaybackError(errorDescription: "Spotify couldn't play this track (\(message)).")
            }
        }
        diagnostics.record("music", "Started a track from search")
        // Spotify needs a moment to switch; then pick up metadata and artwork for the new track.
        try? await Task.sleep(for: .milliseconds(350))
        await refresh()
    }

    // MARK: Artwork (HTTPS from Spotify's CDN only, small bounded cache)

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard settings.settings.loadArtwork, let url else {
            artwork = nil
            return
        }
        if let cached = imageCache.value(for: url) { artwork = cached; return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.image(for: url)
            if image == nil { self.diagnostics.record("music", "Artwork unavailable") }
            if !Task.isCancelled, self.snapshot?.track?.artworkURL == url { self.artwork = image }
        }
    }

    /// Cached image from Spotify's CDN (now-playing artwork and search thumbnails).
    func image(for url: URL) async -> NSImage? {
        guard settings.settings.loadArtwork, ArtworkURLPolicy.validated(url.absoluteString) != nil else { return nil }
        if let cached = imageCache.value(for: url) { return cached }
        if let inFlight = imageLoads[url] { return await inFlight.value }
        let session = artworkSession
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { return nil }
            return NSImage(data: data)
        }
        imageLoads[url] = task
        let image = await task.value
        imageLoads[url] = nil
        if let image { imageCache.insert(image, for: url) }
        return image
    }

    func cachedImage(for url: URL) -> NSImage? { imageCache.value(for: url) }

    func recordDiagnostic(_ message: String) { diagnostics.record("music", message) }

    /// Plain resume: makes this Mac the active Spotify device without bringing Spotify forward.
    func resumeLocally() async throws {
        guard isRunning else { throw PlaybackError(errorDescription: "Spotify isn't running.") }
        _ = try await runner.run(SpotifyScripts.command(.resume))
    }
}

/// Serializes AppleScript execution on a dedicated background queue (NSAppleScript is not
/// re-entrant), so Apple Events never block the main thread.
final class AppleScriptRunner: @unchecked Sendable {
    enum ScriptError: Error, Equatable {
        case notPermitted, needsConsent, notRunning, failed(String)
    }

    /// One process-wide serial queue: OSA/NSAppleScript is not safe to run concurrently, and two
    /// runners executing at once was observed to fail with error -1751.
    private static let sharedQueue = DispatchQueue(label: "Nook.AppleScript", qos: .userInitiated)
    private var queue: DispatchQueue { Self.sharedQueue }
    private var cache: [String: NSAppleScript] = [:]

    static var statusScript: String { SpotifyScripts.status }

    func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script: NSAppleScript
                if let cached = self.cache[source] {
                    script = cached
                } else if let compiled = NSAppleScript(source: source) {
                    self.cache[source] = compiled
                    script = compiled
                } else {
                    continuation.resume(throwing: ScriptError.failed("Could not compile script"))
                    return
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    switch code {
                    case -1743: continuation.resume(throwing: ScriptError.notPermitted)
                    case -1744: continuation.resume(throwing: ScriptError.needsConsent)
                    case -600, -609: continuation.resume(throwing: ScriptError.notRunning)
                    default:
                        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
                        continuation.resume(throwing: ScriptError.failed(message))
                    }
                    return
                }
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }

}
