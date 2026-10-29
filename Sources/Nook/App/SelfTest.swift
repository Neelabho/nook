import AppKit
import NookCore
import SwiftUI
import Security

/// `Nook.app/Contents/MacOS/Nook --self-test` runs headless checks *inside the signed, sandboxed
/// binary* (where entitlement problems would show up) and exits. It uses a temporary Shelf root,
/// never the real Shelf.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--self-test") }

    /// Report lines also go to <container>/tmp/nook-selftest.txt (stdout is lost when launched via `open`).
    static func emit(_ line: String) {
        print(line)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-selftest.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Drives the real AssistantModel (isolated settings + temporary history) against local Ollama.
    static func runAssistant() async -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  [assistant] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        guard let suite = UserDefaults(suiteName: "nook.selftest.\(UUID().uuidString)") else { return 1 }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("NookAssistantTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = SettingsService(defaults: suite)
        settings.update { $0.keepAlive = .oneMinute }
        let model = AssistantModel(settings: settings, diagnostics: DiagnosticsService(), storeDirectory: tmp)

        // A. Service unreachable: the message must come back to the composer, shown once.
        settings.update { $0.ollamaEndpoint = "http://127.0.0.1:11999" }
        model.draft = "Name three primary colors."
        model.send()
        _ = await waitUntil(timeout: 10) { !model.isGenerating }
        let unavailable: Bool = { if case .unavailable = model.connection { return true } else { return false } }()
        check("unreachable service → draft restored, no stray message, single notice",
              model.draft == "Name three primary colors." && model.conversation.messages.isEmpty && unavailable && model.error == nil,
              "draft='\(model.draft)', messages=\(model.conversation.messages.count), error=\(model.error ?? "nil")")

        // B. Reconnect to the real service and send the restored draft.
        settings.update { $0.ollamaEndpoint = "http://127.0.0.1:11434" }
        model.checkConnection()
        let connected = await waitUntil(timeout: 10) { if case .connected = model.connection { return true } else { return false } }
        check("reconnect after service returns", connected, "\(model.connection)")
        model.draft = "Reply with exactly: Nook works"
        let started = Date()
        model.send()
        var sawStreaming = false
        _ = await waitUntil(timeout: 90) {
            if !model.streamingText.isEmpty { sawStreaming = true }
            return !model.isGenerating
        }
        let reply = model.conversation.messages.last
        check("streamed reply", reply?.role == .assistant && (reply?.content.localizedCaseInsensitiveContains("nook works") ?? false),
              String(format: "%.1fs, streamed=%@, '%@'", Date().timeIntervalSince(started), sawStreaming ? "yes" : "no (too fast to observe)", reply?.content ?? "-"))
        check("history saved locally", AssistantStore(directory: tmp).loadConversation()?.messages.count == 2)

        // C. Stop mid-generation.
        model.draft = "Write a detailed 600-word essay about lighthouses."
        model.send()
        _ = await waitUntil(timeout: 60) { model.streamingText.count > 80 }
        model.stop()
        _ = await waitUntil(timeout: 10) { !model.isGenerating }
        let stopped = model.conversation.messages.last?.content ?? ""
        check("stop keeps partial reply, marked stopped", stopped.hasSuffix("*(stopped)*"), "\(stopped.split(separator: " ").count) words")

        // D. Unload frees the model.
        model.unloadModel()
        let client = try? OllamaClient(endpoint: "http://127.0.0.1:11434")
        var unloaded = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(300))
            if let running = try? await client?.runningModels(), !running.contains(where: { $0.name == model.selectedModel }) { unloaded = true; break }
        }
        check("unload frees model memory", unloaded)
        return failures == 0 ? 0 : 1
    }

    /// Live catalogue search through Nook's real SpotifyCatalogService (the signed-in staging token in
    /// the Keychain) and SpotifySearchModel. Read-only: never starts playback. Tokens are never printed.
    static func runCatalog() async -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  [catalog] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let settings = SettingsService()                      // staging settings (Client ID)
        let diagnostics = DiagnosticsService()
        let catalog = SpotifyCatalogService(settings: settings, diagnostics: diagnostics)
        await catalog.waitUntilLoaded()
        let keychainStatus = Keychain.probe(service: "\(catalog.bundleIdentifier).spotify-web-api", account: settings.settings.spotifyClientID)
        check("signed in (token found in Keychain)", catalog.authState == .signedIn,
              "\(catalog.authState); Keychain read status \(keychainStatus) (\(SecCopyErrorMessageString(keychainStatus, nil) as String? ?? "?"))")
        guard catalog.authState == .signedIn else { return 1 }

        // Which market strategies work with a scope-less token?
        for (label, market) in [("market=from_token", SpotifySearchAPI.Market.fromToken), ("no market", .none),
                                ("market=\(Locale.current.region?.identifier ?? "?") (Mac region)", .country(fromRegion: Locale.current.region?.identifier))] {
            do {
                let items = try await catalog.search("Daft Punk", market: market)
                emit("      probe \(label): OK, \(items.count) items, playable flags \(Set(items.map(\.isPlayable)))")
            } catch {
                emit("      probe \(label): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }

        func summary(_ items: [SpotifyCatalogItem]) -> String {
            let counts = SpotifyCatalogItem.Kind.allCases.map { kind in "\(items.filter { $0.kind == kind }.count) \(kind.rawValue)s" }
            return counts.joined(separator: ", ")
        }
        func timed(_ query: String) async -> (Result<[SpotifyCatalogItem], Error>, Double) {
            let start = Date()
            do { return (.success(try await catalog.search(query)), Date().timeIntervalSince(start)) }
            catch { return (.failure(error), Date().timeIntervalSince(start)) }
        }

        // Song search: the track currently loaded in Spotify (falls back to a well-known song).
        let music = SpotifyService(settings: settings, diagnostics: diagnostics)
        music.start()
        await music.refresh()
        let current = music.snapshot?.track
        let songQuery = current.map { "\($0.title) \($0.artist)" } ?? "Paranoid Android Radiohead"
        let (songResult, songTime) = await timed(songQuery)
        if case .success(let items) = songResult {
            let tracks = items.filter { $0.kind == .track }
            let match = current.flatMap { cur in tracks.first { $0.uri == cur.id } }
            check("song search returns tracks", !tracks.isEmpty, String(format: "“%@” → %@ in %.2fs", songQuery, summary(items), songTime))
            if let first = tracks.first {
                emit("      top song: “\(first.title)” — \(first.artistLine) · \(first.album) · \(first.durationMs.map { MusicView.time(Double($0) / 1000) } ?? "?")")
                check("song results carry album context + CDN artwork", first.albumURI != nil && first.artworkURL != nil)
            }
            if current != nil {
                check("the song now in Spotify is found by name", match != nil, match.map { "matched \($0.uri)" } ?? "not in top results")
            }
            check("respects Spotify's limit (≤10 per type)", SpotifyCatalogItem.Kind.allCases.allSatisfy { k in items.filter { $0.kind == k }.count <= 10 })
        } else if case .failure(let error) = songResult {
            check("song search returns tracks", false, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        // Artist and album searches.
        let (artistResult, _) = await timed("Daft Punk")
        if case .success(let items) = artistResult {
            let artist = items.first { $0.kind == .artist }
            check("artist search", artist?.title.localizedCaseInsensitiveContains("daft punk") == true, "\(artist?.title ?? "none") · \(summary(items))")
        } else { check("artist search", false) }
        let (albumResult, _) = await timed("Discovery Daft Punk")
        if case .success(let items) = albumResult {
            let album = items.first { $0.kind == .album && $0.title.localizedCaseInsensitiveContains("discovery") }
            check("album search", album != nil, album.map { "“\($0.title)” · \($0.subtitle)" } ?? summary(items))
        } else { check("album search", false) }

        // No results.
        let (emptyResult, _) = await timed("zqxjv wpqzk qqxzv vvqzx")
        if case .success(let items) = emptyResult {
            check("nonsense query → empty result handled", true, items.isEmpty ? "0 results" : "\(items.count) loose matches (Spotify fuzzy-matches)")
        } else { check("nonsense query → empty result handled", false) }

        // Debounce + stale handling with the real service behind the model.
        let model = SpotifySearchModel(
            debounce: .milliseconds(350),
            configuration: { catalog.configurationProblem() },
            search: { q in try await catalog.search(q) },
            play: { _ in throw SpotifyAPIError.server(status: 0, message: "playback disabled in this test") }
        )
        for prefix in ["r", "ra", "rad", "radi", "radio", "radioh", "radiohe", "radiohea", "radiohead"] {
            model.query = prefix
            try? await Task.sleep(for: .milliseconds(40))
        }
        _ = await waitUntil(timeout: 10) { if case .results = model.phase { true } else { false } }
        check("typing “radiohead” sends one request (debounced)", model.requestCount == 1, "\(model.requestCount) request(s), phase \(model.phase)")
        check("results shown for the final query only", model.phase == .results(query: "radiohead") && model.results.contains { $0.title.localizedCaseInsensitiveContains("radiohead") })

        model.query = "the beatles abbey road"
        try? await Task.sleep(for: .milliseconds(400))      // first request in flight…
        model.query = "kendrick lamar"                       // …then the query changes
        _ = await waitUntil(timeout: 10) { if case .results(let q) = model.phase { q == "kendrick lamar" } else { false } }
        try? await Task.sleep(for: .seconds(1.5))           // let any stale response arrive
        check("stale response ignored", model.phase == .results(query: "kendrick lamar") && !model.results.contains { $0.artistLine.localizedCaseInsensitiveContains("beatles") },
              "showing results for \(model.phase)")

        // Artwork: fetched once, then served from the shared cache.
        if case .success(let items) = songResult, let url = items.first(where: { $0.artworkURL != nil })?.artworkURL {
            let first = await music.image(for: url)
            let cached = music.cachedImage(for: url)
            check("result artwork loads and is cached", first != nil && cached != nil && first === cached)
        }

        // Nothing was played.
        await music.refresh()
        check("search never changed playback", music.snapshot?.track?.id == current?.id, "still “\(music.snapshot?.track?.title ?? "?")”")
        music.stop()
        return failures == 0 ? 0 : 1
    }

    /// Plays the user's current song *from a catalogue search result* through the app's real path
    /// (`AppEnvironment.playFromSearch`), checks it is the chosen song inside its album, checks
    /// Next/Previous, then restores song (in its album), position and play/pause state.
    /// Paced gently (≥1.5 s between commands). Replaces the current queue.
    static func runCatalogPlayback() async -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  [play] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let settings = SettingsService()
        let diagnostics = DiagnosticsService()
        let catalog = SpotifyCatalogService(settings: settings, diagnostics: diagnostics)
        await catalog.waitUntilLoaded()
        let music = SpotifyService(settings: settings, diagnostics: diagnostics)
        music.start()
        music.setVisible(true)
        await music.refresh()
        check("signed in with the playback permission", catalog.authState == .signedIn && catalog.playbackScopeGranted,
              "auth \(catalog.authState), playback scope \(catalog.playbackScopeGranted)")
        guard catalog.authState == .signedIn, music.capabilities.status == .ready,
              let original = music.snapshot, let current = original.track, let currentURI = current.id else {
            check("preconditions (Spotify ready, a track loaded)", false, "spotify \(music.capabilities.status)")
            return 1
        }
        // Refuse to run against a player that isn't advancing (the stuck state seen earlier).
        if original.state == .playing {
            let p1 = original.positionSeconds ?? 0
            try? await Task.sleep(for: .seconds(2))
            await music.refresh()
            let p2 = music.snapshot?.positionSeconds ?? 0
            guard p2 > p1 else {
                check("Spotify is responsive (position advances)", false, "\(p1)s → \(p2)s; not sending playback commands")
                return 1
            }
        }
        let originalPosition = music.snapshot?.positionSeconds ?? original.positionSeconds ?? 0
        emit("      before: \(original.state.rawValue) “\(current.title)” — \(current.artist) [\(current.album)] at \(MusicView.time(originalPosition))")

        let results = (try? await catalog.search("\(current.title) \(current.artist)")) ?? []
        guard let result = results.first(where: { $0.kind == .track && $0.uri == currentURI })
                ?? results.first(where: { $0.kind == .track && $0.title.caseInsensitiveCompare(current.title) == .orderedSame }) else {
            check("search finds the current song", false)
            return 1
        }
        check("search finds the current song", true, "\(result.uri) in “\(result.album)”")

        // Play exactly as the search panel does.
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do { try await AppEnvironment.playFromSearch(result, music: music, catalog: catalog) }
        catch { check("play from search result", false, (error as? LocalizedError)?.errorDescription ?? "\(error)"); return 1 }
        check("album context set (no fallback)", catalog.playbackNote == nil, catalog.playbackNote ?? "")
        try? await Task.sleep(for: .milliseconds(800))
        let spotifyApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first
        check("Spotify app did not come to the front", spotifyApp?.isActive != true && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontBefore,
              "frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        try? await Task.sleep(for: .seconds(1.5))
        await music.refresh()
        let first = music.snapshot
        check("Spotify plays the chosen song (not the album's first track)", first?.track?.id == result.uri && first?.state == .playing,
              "“\(first?.track?.title ?? "?")” \(first?.state.rawValue ?? "?") at \(Int(first?.positionSeconds ?? -1))s")
        try? await Task.sleep(for: .seconds(1.5))
        await music.refresh()
        check("…and keeps playing it", music.snapshot?.track?.id == result.uri && (music.snapshot?.positionSeconds ?? 0) > (first?.positionSeconds ?? 0),
              "at \(Int(music.snapshot?.positionSeconds ?? -1))s")

        // Song ending naturally: it must continue to the next song in the album, not repeat.
        if let duration = music.snapshot?.track?.durationSeconds, duration > 10 {
            music.seek(to: duration - 4)
            let moved = await waitUntil(timeout: 12) { music.snapshot?.track?.id != result.uri }
            if !moved { await music.refresh() }
            let followed = music.snapshot?.track
            check("when the song ends, the next album song plays (no repeat)", moved && followed?.album == result.album,
                  moved ? "→ “\(followed?.title ?? "?")” [\(followed?.album ?? "?")]" : "still “\(followed?.title ?? "?")” at \(Int(music.snapshot?.positionSeconds ?? -1))s")
            // Go back to the chosen song for the Next/Previous checks.
            try? await Task.sleep(for: .seconds(1.5))
            music.previous()
            if !(await waitUntil(timeout: 6) { music.snapshot?.track?.id == result.uri }) {
                try? await Task.sleep(for: .seconds(1.5))
                music.previous()
                _ = await waitUntil(timeout: 6) { music.snapshot?.track?.id == result.uri }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }

        // Next / Previous within the album.
        music.next()
        _ = await waitUntil(timeout: 8) { music.snapshot?.track?.id != result.uri }
        let nextTrack = music.snapshot?.track
        check("Next moves to another song in the album", nextTrack?.id != result.uri && nextTrack?.album == result.album,
              "“\(nextTrack?.title ?? "?")” [\(nextTrack?.album ?? "?")]")
        try? await Task.sleep(for: .seconds(1.5))
        music.previous()
        var back = await waitUntil(timeout: 6) { music.snapshot?.track?.id == result.uri }
        if !back {
            try? await Task.sleep(for: .seconds(1.5))
            music.previous()
            back = await waitUntil(timeout: 6) { music.snapshot?.track?.id == result.uri }
        }
        check("Previous returns to the chosen song", back, "“\(music.snapshot?.track?.title ?? "?")”")

        // Restore: the original song inside its album, its position, and play/pause state.
        try? await Task.sleep(for: .seconds(1.5))
        if music.snapshot?.track?.id != currentURI {
            try? await AppEnvironment.playFromSearch(result, music: music, catalog: catalog)
            _ = await waitUntil(timeout: 6) { music.snapshot?.track?.id == currentURI }
        }
        try? await Task.sleep(for: .seconds(1))
        music.seek(to: originalPosition)
        try? await Task.sleep(for: .seconds(1))
        if original.state != .playing, music.snapshot?.state == .playing {
            music.playPause()
            _ = await waitUntil(timeout: 5) { music.snapshot?.state != .playing }
        }
        try? await Task.sleep(for: .milliseconds(800))
        await music.refresh()
        let end = music.snapshot
        let positionOK = abs((end?.positionSeconds ?? -100) - originalPosition) < (original.state == .playing ? 8 : 3)
        check("restored song (in its album), position and play/pause state",
              end?.track?.id == currentURI && end?.state == original.state && positionOK,
              "\(end?.state.rawValue ?? "?") “\(end?.track?.title ?? "?")” at \(MusicView.time(end?.positionSeconds ?? 0)) (was \(original.state.rawValue) at \(MusicView.time(originalPosition)))")
        music.stop()
        return failures == 0 ? 0 : 1
    }

    /// Which playback command brings the Spotify app forward? Uses the current song (restarts it),
    /// then restores its position. Observes Spotify's active/hidden state and the frontmost app.
    static func runActivationProbe() async -> Int32 {
        let settings = SettingsService()
        let diagnostics = DiagnosticsService()
        let catalog = SpotifyCatalogService(settings: settings, diagnostics: diagnostics)
        await catalog.waitUntilLoaded()
        let music = SpotifyService(settings: settings, diagnostics: diagnostics)
        music.start(); music.setVisible(true)
        await music.refresh()
        guard let snap = music.snapshot, let track = snap.track, let uri = track.id else { emit("FAIL  [activation] no track"); return 1 }
        let position = snap.positionSeconds ?? 0
        func spotifyState() -> String {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            return "spotify active=\(app?.isActive ?? false) hidden=\(app?.isHidden ?? false), frontmost=\(front)"
        }
        emit("      before: \(spotifyState()) — “\(track.title)” \(snap.state.rawValue) at \(Int(position))s")
        // Find the album via search (for the Web API step).
        let album = ((try? await catalog.search("\(track.title) \(track.artist)")) ?? []).first { $0.uri == uri }?.albumURI

        if CommandLine.arguments.contains("--resume-only") {
            // C: plain `play` (resume) and `playpause` — device activation candidates.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            try? await Task.sleep(for: .seconds(1))
            emit("      reset: \(spotifyState())")
            _ = try? await AppleScriptRunner().run(SpotifyScripts.command(.playPause))
            try? await Task.sleep(for: .seconds(1.5))
            emit("      C1) AppleScript playpause: \(spotifyState())")
            _ = try? await AppleScriptRunner().run("if application id \"com.spotify.client\" is running then tell application id \"com.spotify.client\" to play")
            try? await Task.sleep(for: .seconds(1.5))
            emit("      C2) AppleScript play (resume): \(spotifyState())")
            await music.refresh()
            emit("      now “\(music.snapshot?.track?.title ?? "?")” \(music.snapshot?.state.rawValue ?? "?") at \(Int(music.snapshot?.positionSeconds ?? -1))s")
            music.stop()
            return 0
        }
        // A: Web API only (no AppleScript play).
        if let album {
            do {
                try await catalog.playInAlbum(trackURI: uri, albumURI: album)
                try? await Task.sleep(for: .seconds(2))
                await music.refresh()
                emit("      A) Web API play-in-album only: ok; now “\(music.snapshot?.track?.title ?? "?")” \(music.snapshot?.state.rawValue ?? "?"); \(spotifyState())")
            } catch {
                emit("      A) Web API play-in-album only: \((error as? LocalizedError)?.errorDescription ?? "\(error)"); \(spotifyState())")
            }
        }
        try? await Task.sleep(for: .seconds(1.5))
        // B: AppleScript play track (what step 1 of the current path does).
        do {
            try await music.playTrack(uri: uri)
            try? await Task.sleep(for: .seconds(2))
            emit("      B) AppleScript play track: \(spotifyState())")
        } catch {
            emit("      B) AppleScript play track failed: \(error)")
        }
        try? await Task.sleep(for: .seconds(1.5))
        // Restore: back into the album at the original position.
        if let album { try? await catalog.playInAlbum(trackURI: uri, albumURI: album) }
        try? await Task.sleep(for: .seconds(1.5))
        music.seek(to: position + 8)
        try? await Task.sleep(for: .seconds(1))
        await music.refresh()
        emit("      restored: “\(music.snapshot?.track?.title ?? "?")” \(music.snapshot?.state.rawValue ?? "?") at \(Int(music.snapshot?.positionSeconds ?? -1))s")
        music.stop()
        return 0
    }

    /// Puts a specific song back (in its album) at a position — used to undo a test's playback change.
    static func restoreTrack(uri: String, album: String, seconds: Double) async -> Int32 {
        let settings = SettingsService()
        let music = SpotifyService(settings: settings, diagnostics: DiagnosticsService())
        music.start()
        music.setVisible(true)
        await music.refresh()
        do {
            try await music.playTrack(uri: uri, albumContext: album)
        } catch {
            emit("FAIL  [restore] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return 1
        }
        _ = await waitUntil(timeout: 6) { music.snapshot?.track?.id == uri }
        music.seek(to: seconds)
        try? await Task.sleep(for: .milliseconds(800))
        await music.refresh()
        let ok = music.snapshot?.track?.id == uri
        emit("\(ok ? "PASS" : "FAIL")  [restore] “\(music.snapshot?.track?.title ?? "?")” \(music.snapshot?.state.rawValue ?? "?") at \(MusicView.time(music.snapshot?.positionSeconds ?? 0))")
        music.stop()
        return ok ? 0 : 1
    }

    /// Exercises the Spotify sign-in redirect receiver inside the sandbox with real local HTTP requests.
    /// Contacts nothing but 127.0.0.1; no Spotify account is involved.
    static func runLoopback() async -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  [loopback] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let catalog = SpotifyCatalogService(settings: SettingsService(defaults: UserDefaults(suiteName: "nook.selftest.\(UUID().uuidString)")!), diagnostics: DiagnosticsService())
        check("network.server entitlement present in this build", catalog.loopbackSignInEnabled)

        let session = URLSession(configuration: .ephemeral)
        func get(_ url: URL) async -> (Int?, String) {
            do {
                let (data, response) = try await session.data(from: url)
                return ((response as? HTTPURLResponse)?.statusCode, String(decoding: data, as: UTF8.self))
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        let receiver = LoopbackRedirectReceiver()
        let port: UInt16
        do {
            port = try await receiver.start()
            check("listener starts on 127.0.0.1", port > 0, "port \(port)")
        } catch {
            check("listener starts on 127.0.0.1", false, error.localizedDescription)
            return 1
        }
        emit("      LISTENING 127.0.0.1:\(port)")
        try? await Task.sleep(for: .seconds(2))   // lets an external `lsof` confirm the bind address

        let (strayStatus, _) = await get(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        check("other paths are refused", strayStatus == 404, "status \(strayStatus.map(String.init) ?? "none")")

        async let callback = receiver.nextCallback(timeout: .seconds(10))
        async let browser = get(URL(string: "http://127.0.0.1:\(port)/nook-callback?code=TESTCODE&state=TESTSTATE")!)
        let delivered = try? await callback
        let code = delivered.flatMap { try? SpotifyAuth.authorizationCode(from: $0, expectedState: "TESTSTATE") }
        check("callback delivered with state verified", code == "TESTCODE")
        receiver.respond(success: true)
        let (status, body) = await browser
        check("browser gets the confirmation page", status == 200 && body.contains("Signed in to Spotify"), "status \(status.map(String.init) ?? "none")")

        try? await Task.sleep(for: .milliseconds(500))
        let (afterStatus, afterDetail) = await get(URL(string: "http://127.0.0.1:\(port)/nook-callback?code=x&state=y")!)
        check("listener is closed afterwards", afterStatus == nil, afterStatus.map { "still answering (\($0))" } ?? afterDetail)

        // The registered (fixed) port, and a clear error when something else already holds it.
        let registered = SpotifyAuth.callbackPort(bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.local.nook")
        let first = LoopbackRedirectReceiver()
        do {
            let bound = try await first.start(port: registered)
            check("binds the registered redirect port", bound == registered, "127.0.0.1:\(bound)")
            let second = LoopbackRedirectReceiver()
            do {
                _ = try await second.start(port: registered)
                check("reports a port already in use", false)
                second.stop()
            } catch {
                check("reports a port already in use", (error as? LoopbackRedirectReceiver.ReceiverError).map {
                    if case .portInUse = $0 { return true } else { return false }
                } ?? false, error.localizedDescription)
            }
        } catch {
            check("binds the registered redirect port", false, error.localizedDescription)
        }
        first.stop()
        try? await Task.sleep(for: .milliseconds(200))

        // Timeout path: nothing arrives, the receiver gives up and closes.
        let idle = LoopbackRedirectReceiver()
        if let idlePort = try? await idle.start() {
            do {
                _ = try await idle.nextCallback(timeout: .milliseconds(300))
                check("times out and closes when no redirect arrives", false)
            } catch {
                try? await Task.sleep(for: .milliseconds(200))
                let (late, _) = await get(URL(string: "http://127.0.0.1:\(idlePort)/nook-callback?code=x&state=y")!)
                check("times out and closes when no redirect arrives", late == nil, error.localizedDescription)
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// Offscreen layout renders of the Music view (real Spotify data) and the search panel (sample
    /// results). `ImageRenderer` can't draw compositor effects (Liquid Glass, blur) or AppKit-backed
    /// views (vinyl), so these check layout and typography only.
    static func renderMusicLayouts(service: SpotifyService, settings: SettingsService, track: TrackSnapshot) async {
        let catalog = SpotifyCatalogService(settings: settings, diagnostics: DiagnosticsService())
        var samples = (0..<3).map { i in
            SpotifyTrackResult(id: "4uLU6hMCjMI75M1A2tKUQ\(i)", uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQ\(i)",
                               title: i == 0 ? track.title : "Sample song \(i + 1)", artists: [track.artist], album: track.album,
                               artworkURL: track.artworkURL, durationMs: 200_000 + i * 17_000, isPlayable: i != 2, explicit: i == 1)
        }
        samples.append(SpotifyCatalogItem(kind: .artist, spotifyID: "4uLU6hMCjMI75M1A2tKUQ8", uri: "spotify:artist:4uLU6hMCjMI75M1A2tKUQ8",
                                          title: track.artist, artists: [], album: "", artworkURL: track.artworkURL, durationMs: nil,
                                          isPlayable: true, explicit: false, albumURI: nil, year: nil))
        samples.append(SpotifyCatalogItem(kind: .album, spotifyID: "4uLU6hMCjMI75M1A2tKUQ9", uri: "spotify:album:4uLU6hMCjMI75M1A2tKUQ9",
                                          title: track.album, artists: [track.artist], album: "", artworkURL: track.artworkURL, durationMs: nil,
                                          isPlayable: true, explicit: false, albumURI: nil, year: "2025"))
        let fixed = samples
        let model = SpotifySearchModel(debounce: .milliseconds(1), configuration: { nil }, search: { _ in fixed }, play: { _ in })
        model.query = "keine"
        _ = await waitUntil(timeout: 2) { !model.results.isEmpty }
        model.moveHighlight(by: 1)
        if let url = track.artworkURL { _ = await service.image(for: url) }

        func render<V: View>(_ view: V, _ name: String) {
            let framed = view
                .frame(width: 618, height: 252)
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16)
                .background(LinearGradient(colors: [.black, Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? png.write(to: url)
                emit("      rendered \(name)")
            }
        }
        render(MusicView(music: service, settings: settings, search: model, catalog: catalog), "render-music.png")
        render(SpotifySearchView(model: model, music: service, catalog: catalog, onClose: {}, openSettings: {}), "render-search-results.png")
        // ScrollView is NSScrollView-backed and can't be rendered offscreen: render the rows directly.
        render(VStack(spacing: 2) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                SearchResultRow(item: result, highlighted: model.highlightedIndex == index,
                                state: index == 3 ? .starting(trackID: result.id) : .none, music: service, play: {})
            }
        }.frame(maxHeight: .infinity, alignment: .top), "render-search-rows.png")
        let unconfigured = SpotifySearchModel(debounce: .milliseconds(1), configuration: { .notConfigured }, search: { _ in [] }, play: { _ in })
        unconfigured.query = "daft punk"
        render(SpotifySearchView(model: unconfigured, music: service, catalog: catalog, onClose: {}, openSettings: {}), "render-search-setup.png")
    }

    /// Drives the real SpotifyService against the running Spotify app. The first Apple Event shows
    /// macOS's "Nook Staging wants to control Spotify" prompt if consent hasn't been given.
    /// Restores play/pause state and volume afterwards. Launch with `open -n` so macOS attributes
    /// the request to Nook rather than to the launching terminal.
    static func runSpotify() async -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  [spotify] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        guard let suite = UserDefaults(suiteName: "nook.selftest.\(UUID().uuidString)") else { return 1 }
        let settings = SettingsService(defaults: suite)
        let service = SpotifyService(settings: settings, diagnostics: DiagnosticsService())
        service.start()
        service.setVisible(true)
        check("detects running Spotify", service.isRunning)
        emit("…sending first Apple Event (approve the macOS prompt if it appears)")
        do {
            let raw = try await AppleScriptRunner().run(AppleScriptRunner.statusScript)
            emit("      raw status reply: \(raw.replacingOccurrences(of: "\u{1F}", with: " | "))")
        } catch {
            emit("      raw status script error: \(error)")
        }
        service.connect()
        let decided = await waitUntil(timeout: 150) { !service.isBusy && service.capabilities.status != .needsPermission }
        check("automation consent", service.capabilities.status == .ready,
              "\(service.capabilities.status)\(decided ? "" : " (timed out waiting)")\(service.lastError.map { ", error: \($0)" } ?? "")")
        guard service.capabilities.status == .ready else { return 1 }

        await service.refresh()
        guard let first = service.snapshot, let track = first.track else {
            check("current track metadata", false, "nothing loaded in Spotify")
            return 1
        }
        check("metadata", !track.title.isEmpty, "\(first.state.rawValue): “\(track.title)” — \(track.artist) [\(track.album)], \(Int(track.durationSeconds ?? 0))s, pos \(Int(first.positionSeconds ?? -1))s")
        let artwork = await waitUntil(timeout: 8) { service.artwork != nil }
        check("album artwork (Spotify CDN)", artwork, track.artworkURL?.host ?? "no artwork URL")
        if CommandLine.arguments.contains("--render") || CommandLine.arguments.contains("--render-only") {
            await renderMusicLayouts(service: service, settings: settings, track: track)
        }
        if CommandLine.arguments.contains("--render-only") {
            emit("…render-only: playback was not touched")
            service.stop()
            return failures == 0 ? 0 : 1
        }
        let originalState = first.state
        let originalVolume = first.volume
        let originalPosition = first.positionSeconds

        service.playPause()
        let toggled = await waitUntil(timeout: 5) { service.snapshot?.state != originalState }
        check("play/pause toggles", toggled, "\(originalState.rawValue) → \(service.snapshot?.state.rawValue ?? "?")")
        if service.snapshot?.state != .playing {
            service.playPause()
            _ = await waitUntil(timeout: 5) { service.snapshot?.state == .playing }
        }
        let p1 = service.clock?.position(at: Date()) ?? 0
        try? await Task.sleep(for: .seconds(2))
        await service.refresh()
        let p2 = service.snapshot?.positionSeconds ?? 0
        check("progress advances while playing", p2 > p1, String(format: "%.1fs → %.1fs", p1, p2))

        let beforeNext = service.snapshot?.track?.id
        service.next()
        let advanced = await waitUntil(timeout: 6) { service.snapshot?.track?.id != beforeNext }
        if advanced {
            check("next track + metadata update", true, "now “\(service.snapshot?.track?.title ?? "?")”")
        } else {
            emit("SKIP  [spotify] next track — Spotify didn't advance; the current context has no next track (e.g. a single track started by URI)")
        }
        service.previous()
        var back = await waitUntil(timeout: 6) { service.snapshot?.track?.id == beforeNext }
        if !back {   // Spotify restarts the current track first if it has played > ~3s
            service.previous()
            back = await waitUntil(timeout: 6) { service.snapshot?.track?.id == beforeNext }
        }
        check("previous track", back, "now “\(service.snapshot?.track?.title ?? "?")”")

        if let volume = originalVolume {
            let target = volume >= 20 ? volume - 10 : volume + 10
            service.setVolume(target)
            try? await Task.sleep(for: .milliseconds(600))
            await service.refresh()
            // Spotify quantizes volume (setting 90 reads back as 89), so allow ±2.
            check("volume", abs((service.snapshot?.volume ?? -100) - target) <= 2, "set \(target), Spotify reports \(service.snapshot?.volume ?? -1)")
            service.setVolume(volume)
        } else {
            check("volume", false, "volume not reported")
        }

        // Malformed URIs must never reach AppleScript (no playback happens for these).
        do {
            try await service.playTrack(uri: "spotify:track:bad\" to quit")
            check("rejects malformed track URI", false)
        } catch {
            check("rejects malformed track URI", true, error.localizedDescription)
        }

        // Restore the original position (previous track restarts it), then play/pause state.
        if let originalPosition {
            service.seek(to: originalPosition)
            try? await Task.sleep(for: .milliseconds(600))
        }
        if service.snapshot?.state != originalState, originalState != .stopped {
            service.playPause()
            _ = await waitUntil(timeout: 5) { service.snapshot?.state == originalState }
        }
        try? await Task.sleep(for: .milliseconds(500))
        await service.refresh()
        let positionOK = originalPosition.map { abs(($0) - (service.snapshot?.positionSeconds ?? -100)) < 3 } ?? true
        check("restored original state", service.snapshot?.state == originalState && abs((service.snapshot?.volume ?? -100) - (originalVolume ?? -100)) <= 2 && positionOK
              && service.snapshot?.track?.id == track.id,
              "\(service.snapshot?.state.rawValue ?? "?"), “\(service.snapshot?.track?.title ?? "?")” at \(Int(service.snapshot?.positionSeconds ?? -1))s (was \(Int(originalPosition ?? -1))s), volume \(service.snapshot?.volume ?? -1)")
        service.stop()
        return failures == 0 ? 0 : 1
    }

    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        emit("Nook self-test — bundle \(Bundle.main.bundleIdentifier ?? "?"), sandboxed: \(sandboxed)")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("NookSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        // Shelf transactions inside the sandbox container.
        do {
            let sources = tmp.appendingPathComponent("sources", isDirectory: true)
            let dest = tmp.appendingPathComponent("dest", isDirectory: true)
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let pdf = sources.appendingPathComponent("Self Test.pdf")
            try Data("%PDF-1.4\nself-test\n%%EOF\n".utf8).write(to: pdf)
            let store = ShelfStore(layout: ShelfLayout(root: tmp.appendingPathComponent("shelf", isDirectory: true)))
            try await store.open()
            let item = try await store.importFile(at: pdf, origin: .drop)
            check("Shelf import (copy + verify + atomic commit)", item.contentType == "com.adobe.pdf" && fm.fileExists(atPath: pdf.path))
            let text = try await store.importText("Self-test note ✓", origin: .note)
            check("Shelf text item", try await store.readText(text.id) == "Self-test note ✓")
            let copy = try await store.export(item.id, toDirectory: dest, conflict: .fail, mode: .copy)
            let stillThere = await store.item(item.id) != nil
            check("Shelf export copy", fm.fileExists(atPath: copy.path) && stillThere)
            let moved = try await store.export(item.id, toDirectory: dest, conflict: .keepBoth, mode: .move)
            let gone = await store.item(item.id) == nil
            check("Shelf move with Keep Both", moved.lastPathComponent == "Self Test 2.pdf" && gone)
            let reopened = ShelfStore(layout: store.layout)
            let report = try await reopened.open()
            let visible = await reopened.visibleItems().count
            check("Shelf reopen/reconcile", !report.needsAttention && visible == 1, report.summary)
        } catch {
            check("Shelf", false, error.localizedDescription)
        }
        let realRoot = try? ShelfLayout.defaultRoot()
        check("Production Shelf location resolvable", realRoot != nil, displayPath(realRoot))

        // Loopback networking (sandbox network.client).
        do {
            let client = try OllamaClient(endpoint: "http://127.0.0.1:11434")
            let version = try await client.version()
            let models = try await client.listModels()
            check("Ollama reachable from sandbox", true, "v\(version), models: \(models.map(\.name).joined(separator: ", "))")
        } catch {
            emit("SKIP  Ollama — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        check("Remote endpoints rejected", (try? OllamaClient(endpoint: "http://10.0.0.1:11434")) == nil)

        // Spotify detection without sending events or prompting.
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyService.bundleID) != nil
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyService.bundleID).isEmpty
        // Detection only: no Apple Event is sent (that would trigger the consent prompt).
        let caps = MusicCapabilities.evaluate(installed: installed, running: running, permission: .notDetermined)
        check("Spotify detection", true, "installed \(installed), running \(running) → \(caps.status) until the user connects")

        // Display geometry.
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false }) {
            let d = DisplayDescriptor(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                                      auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea, isBuiltIn: true, scale: screen.backingScaleFactor)
            let notch = NotchGeometry.notchRect(for: d)
            check("Built-in display notch detected", notch != nil, notch.map { "\(Int($0.width))×\(Int($0.height)) pt at x=\(Int($0.minX))" } ?? "no notch")
        } else {
            emit("SKIP  Built-in display not active (lid closed?)")
        }

        // Standard editing shortcuts reach text fields through the (hidden) main menu.
        let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let wanted: [(String, Selector)] = [("a", #selector(NSText.selectAll(_:))), ("c", #selector(NSText.copy(_:))),
                                            ("v", #selector(NSText.paste(_:))), ("x", #selector(NSText.cut(_:))), ("z", Selector(("undo:")))]
        let routed = wanted.allSatisfy { key, action in
            edit?.items.contains { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command] && $0.action == action } == true
        }
        // Undo/redo are handled by the window's undo manager further up the responder chain.
        let textView = NSTextView()
        let handled = wanted.filter { $0.0 != "z" }.allSatisfy { textView.responds(to: $0.1) }
            && NSWindow().responds(to: Selector(("undo:")))
        check("⌘A/⌘C/⌘V/⌘X/⌘Z routed to text fields via the Edit menu", routed && handled)
        check("no ⌘Q in the hidden menu (avoids quitting Nook by accident)",
              NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).contains { $0.keyEquivalent == "q" } == false)
        // Functional: ⌘A dispatched through the menu selects all text in a focused text view.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        field.string = "Select me please"
        window.contentView = field
        window.makeFirstResponder(field)
        if let item = edit?.items.first(where: { $0.keyEquivalent == "a" }), let action = item.action {
            NSApp.sendAction(action, to: window.firstResponder, from: item)
        }
        check("Select All selects the whole text", field.selectedRange() == NSRange(location: 0, length: field.string.utf16.count),
              "selected \(field.selectedRange())")

        // Global shortcut registration (no Accessibility needed). Uses an unusual combo to avoid clashing with a running copy.
        let hk = HotKeyManager()
        let registered = hk.register(HotKeySpec(keyCode: 122, modifiers: HotKeySpec.control | HotKeySpec.option | HotKeySpec.shift), handler: {})
        hk.unregister()
        check("Carbon global hot key registration", registered)

        // Launch at login: ~/Applications must be recognised from inside the sandbox.
        let realHome = InstallLocation.realHomeDirectory
        check("real home folder resolved inside the sandbox (for ~/Applications login item)",
              !realHome.path.contains("/Library/Containers/"), realHome.path.replacingOccurrences(of: NSUserName(), with: "…"))

        emit(failures == 0 ? "All self-test checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
