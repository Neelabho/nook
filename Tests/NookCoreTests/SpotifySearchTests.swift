import AppKit
import Foundation
import Testing
@testable import NookCore

func track(_ n: Int, playable: Bool = true) -> SpotifyTrackResult {
    let id = String(repeating: "a", count: 21) + String(n % 10)
    return SpotifyTrackResult(id: id, uri: "spotify:track:\(id)", title: "Song \(n)", artists: ["Artist \(n)"], album: "Album", artworkURL: nil, durationMs: 180_000, isPlayable: playable)
}

/// Records searches; each query can be given a delay to simulate slow responses.
final class SearchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    var delays: [String: Duration] = [:]
    var failure: Error?
    var queries: [String] { lock.withLock { _queries } }

    func search(_ q: String) async throws -> [SpotifyTrackResult] {
        lock.withLock { _queries.append(q) }
        if let d = delays[q] { try await Task.sleep(for: d) }
        if let failure { throw failure }
        if q.contains("nothing") { return [] }
        return [track(q.count), track(q.count + 1)]
    }
}

@MainActor
func settle(_ model: SpotifySearchModel, timeout: Duration = .seconds(2), until: () -> Bool) async {
    let start = ContinuousClock.now
    while !until() && ContinuousClock.now - start < timeout {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Spotify search model")
@MainActor
struct SpotifySearchModelTests {
    func make(_ recorder: SearchRecorder, debounce: Duration = .milliseconds(80), configured: SpotifyAPIError? = nil,
              play: @escaping @MainActor (SpotifyTrackResult) async throws -> Void = { _ in }) -> SpotifySearchModel {
        SpotifySearchModel(debounce: debounce, configuration: { configured }, search: { try await recorder.search($0) }, play: play)
    }

    @Test func debouncesTypingIntoASingleRequest() async {
        let recorder = SearchRecorder()
        let model = make(recorder)
        for prefix in ["d", "da", "daf", "daft", "daft p", "daft pu", "daft punk"] { model.query = prefix }
        await settle(model) { if case .results = model.phase { true } else { false } }
        #expect(recorder.queries == ["daft punk"])
        #expect(model.requestCount == 1)
        #expect(model.results.count == 2)
    }

    @Test func tooShortQueriesNeverSearch() async {
        let recorder = SearchRecorder()
        let model = make(recorder)
        model.query = "a"
        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.queries.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func staleSlowResponseIsIgnored() async {
        let recorder = SearchRecorder()
        recorder.delays["slow query"] = .milliseconds(400)
        let model = make(recorder, debounce: .milliseconds(10))
        model.query = "slow query"
        await settle(model) { recorder.queries.count == 1 }
        model.query = "fast"
        await settle(model) { if case .results(let q) = model.phase { q == "fast" } else { false } }
        try? await Task.sleep(for: .milliseconds(500))   // let the slow one finish
        #expect(model.phase == .results(query: "fast"))
        #expect(model.results.first?.title == "Song 4")
    }

    @Test func noResultsAndErrorsAreReported() async {
        let recorder = SearchRecorder()
        let model = make(recorder, debounce: .milliseconds(10))
        model.query = "nothing here"
        await settle(model) { if case .noResults = model.phase { true } else { false } }
        #expect(model.phase == .noResults(query: "nothing here"))

        recorder.failure = SpotifyAPIError.rateLimited(retryAfter: 3)
        model.query = "anything"
        await settle(model) { if case .failed = model.phase { true } else { false } }
        #expect(model.phase == .failed("Spotify is limiting requests. Try again in 3s."))
    }

    @Test func expiredSignInAsksForSetupInsteadOfFailing() async {
        let recorder = SearchRecorder()
        recorder.failure = SpotifyAPIError.unauthorized
        let model = make(recorder, debounce: .milliseconds(10))
        model.query = "song"
        await settle(model) { if case .needsSetup = model.phase { true } else { false } }
        #expect(model.phase == .needsSetup(SpotifyAPIError.unauthorized.errorDescription!))
    }

    @Test func unconfiguredSearchSendsNoRequest() async {
        let recorder = SearchRecorder()
        let model = make(recorder, configured: .notConfigured)
        model.query = "anything"
        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.queries.isEmpty)
        #expect(model.phase == .needsSetup(SpotifyAPIError.notConfigured.errorDescription!))
    }

    @Test func returnSearchesImmediatelyWithoutWaitingForDebounce() async {
        let recorder = SearchRecorder()
        let model = make(recorder, debounce: .seconds(30))
        model.query = "now please"
        model.submit()
        await settle(model) { if case .results = model.phase { true } else { false } }
        #expect(recorder.queries == ["now please"])
    }

    @Test func browsingNeverPlays_onlyExplicitActionsDo() async {
        let recorder = SearchRecorder()
        var played: [String] = []
        let model = make(recorder, debounce: .milliseconds(10)) { played.append($0.id) }
        model.query = "browse only"
        await settle(model) { !model.results.isEmpty }
        model.moveHighlight(by: 1)
        model.moveHighlight(by: 1)
        model.moveHighlight(by: 5)          // clamps
        #expect(model.highlightedIndex == 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(played.isEmpty, "highlighting must not play")

        model.submit()                       // Return on a highlighted row plays it
        await settle(model) { if case .started = model.playback { true } else { false } }
        #expect(played == [model.results[1].id])
        #expect(model.playback == .started(trackID: model.results[1].id))
    }

    @Test func typingResetsHighlightSoReturnSearchesAgain() async {
        let recorder = SearchRecorder()
        var played = 0
        let model = make(recorder, debounce: .milliseconds(10)) { _ in played += 1 }
        model.query = "first"
        await settle(model) { !model.results.isEmpty }
        model.moveHighlight(by: 1)
        model.query = "second"
        #expect(model.highlightedIndex == nil)
        model.submit()
        await settle(model) { if case .results(let q) = model.phase { q == "second" } else { false } }
        #expect(played == 0)
    }

    @Test func playbackFailuresAndUnplayableTracksAreReported() async {
        let recorder = SearchRecorder()
        struct Boom: LocalizedError { var errorDescription: String? { "Spotify isn't running." } }
        let model = make(recorder) { _ in throw Boom() }
        let ok = track(1)
        model.play(ok)
        await settle(model) { if case .failed = model.playback { true } else { false } }
        #expect(model.playback == .failed(trackID: ok.id, message: "Spotify isn't running."))

        let blocked = track(2, playable: false)
        model.play(blocked)
        #expect(model.playback == .failed(trackID: blocked.id, message: "This track isn't available to play in your region."))
    }

    @Test func clearResetsEverything() async {
        let recorder = SearchRecorder()
        let model = make(recorder, debounce: .milliseconds(10))
        model.query = "something"
        await settle(model) { !model.results.isEmpty }
        model.clear()
        #expect(model.query.isEmpty && model.results.isEmpty && model.phase == .idle && model.highlightedIndex == nil)
    }
}

@Suite("Spotify Web API helpers")
struct SpotifyWebAPITests {
    @Test func buildsSearchRequest() throws {
        let request = try #require(SpotifySearchAPI.request(query: "  Daft Punk & friends ", accessToken: "tok", limit: 99))
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "api.spotify.com")
        #expect(items["q"] == "Daft Punk & friends")
        #expect(items["type"] == "track,artist,album")
        #expect(items["limit"] == "10", "Spotify caps limit at 10 per type (Feb 2026)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(items["market"] == nil, "no market by default")
        let withCountry = try #require(SpotifySearchAPI.request(query: "x", accessToken: "t", market: .country(fromRegion: "in")))
        #expect(withCountry.url!.absoluteString.contains("market=IN"))
        #expect(SpotifySearchAPI.Market.country(fromRegion: "419") == .none)
        #expect(SpotifySearchAPI.Market.country(fromRegion: nil) == .none)
        #expect(request.url!.absoluteString.contains("Daft%20Punk%20%26%20friends"))
        #expect(SpotifySearchAPI.request(query: "   ", accessToken: "tok") == nil)
    }

    @Test func parsesSearchResponse() throws {
        let json = """
        {"tracks":{"items":[
          {"id":"4uLU6hMCjMI75M1A2tKUQC","uri":"spotify:track:4uLU6hMCjMI75M1A2tKUQC","name":"Never Gonna Give You Up",
           "duration_ms":213573,"explicit":false,"is_playable":true,
           "artists":[{"name":"Rick Astley"}],
           "album":{"name":"Whenever You Need Somebody","uri":"spotify:album:6N9PS4QXF1D0OWPk0Sxtb4","images":[
             {"url":"https://i.scdn.co/image/big","width":640},{"url":"https://i.scdn.co/image/small","width":64},
             {"url":"https://evil.example.com/x","width":300}]}},
          {"id":"bad id","name":"Broken"},
          {"id":"0000000000000000000000","name":"Unavailable","is_playable":false,"artists":[],"album":{"name":"A","images":[]}}
        ]}}
        """
        let results = try SpotifySearchAPI.parse(Data(json.utf8))
        #expect(results.count == 2)
        #expect(results[0].title == "Never Gonna Give You Up")
        #expect(results[0].artistLine == "Rick Astley")
        #expect(results[0].artworkURL?.absoluteString == "https://i.scdn.co/image/small")
        #expect(results[1].isPlayable == false)
        #expect(results[0].albumURI == "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4")
        #expect(results[1].albumURI == nil, "album without a uri")
        #expect(throws: SpotifyAPIError.malformedResponse) { try SpotifySearchAPI.parse(Data("{}".utf8)) }
    }

    @Test func parsesArtistsAndAlbums() throws {
        let json = """
        {"tracks":{"items":[]},
         "artists":{"items":[{"id":"4tZwfgrHOc3mvqYlEYSvVi","name":"Daft Punk","images":[{"url":"https://i.scdn.co/image/a","width":160}]},
                             {"id":"nope","name":"Bad"}]},
         "albums":{"items":[{"id":"2noRn2Aes5aoNVsU6iWThc","name":"Discovery","release_date":"2001-03-12",
                             "artists":[{"name":"Daft Punk"}],"images":[{"url":"https://i.scdn.co/image/b","width":300}]}]}}
        """
        let results = try SpotifySearchAPI.parse(Data(json.utf8))
        #expect(results.map(\.kind) == [.artist, .album])
        #expect(results[0].uri == "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi" && results[0].subtitle == "Artist")
        #expect(results[1].uri == "spotify:album:2noRn2Aes5aoNVsU6iWThc")
        #expect(results[1].subtitle == "Album · Daft Punk · 2001")
        #expect(Set(results.map(\.id)).count == 2)
    }

    @Test func quotaExceededIsDistinguishedFromRateLimit() {
        #expect(SpotifyAPIError.from(status: 429, data: Data(#"{"reason":"QUOTA_EXCEEDED"}"#.utf8), headers: [:]) == .quotaExceeded)
    }

    @Test func playCommandsForAlbumsAndArtists() throws {
        let album = try #require(SpotifyScripts.playCommand(uri: "spotify:album:2noRn2Aes5aoNVsU6iWThc", contextURI: "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4"))
        #expect(album.contains("play track \"spotify:album:2noRn2Aes5aoNVsU6iWThc\"") && !album.contains("in context"))
        #expect(SpotifyScripts.playCommand(uri: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi")?.contains("play track \"spotify:artist:4tZwfgrHOc3mvqYlEYSvVi\"") == true)
        #expect(SpotifyScripts.playCommand(uri: "spotify:playlist:4tZwfgrHOc3mvqYlEYSvVi") == nil)
        #expect(SpotifyScripts.playCommand(uri: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi\" & \"x") == nil)
    }

    @Test func loopbackCallbackParsing() throws {
        let ok = Data("GET /nook-callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n".utf8)
        let url = try #require(LoopbackCallback.callbackURL(fromRequest: ok, port: 5000))
        #expect(try SpotifyAuth.authorizationCode(from: url, expectedState: "xyz") == "abc")
        #expect(LoopbackCallback.callbackURL(fromRequest: Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8), port: 5000) == nil)
        #expect(LoopbackCallback.callbackURL(fromRequest: Data("POST /nook-callback?code=a HTTP/1.1\r\n\r\n".utf8), port: 5000) == nil)
        #expect(LoopbackCallback.callbackURL(fromRequest: Data("GET /nook-callbackevil HTTP/1.1\r\n\r\n".utf8), port: 5000) == nil)
        let page = String(decoding: LoopbackCallback.response(success: true), as: UTF8.self)
        #expect(page.hasPrefix("HTTP/1.1 200 OK") && page.contains("Connection: close") && !page.contains("http"))
    }

    @Test func mapsHTTPErrors() {
        #expect(SpotifyAPIError.from(status: 401, data: Data(), headers: [:]) == .unauthorized)
        #expect(SpotifyAPIError.from(status: 429, data: Data(), headers: ["Retry-After": "7"]) == .rateLimited(retryAfter: 7))
        #expect(SpotifyAPIError.from(status: 403, data: Data(#"{"error":{"status":403,"message":"Forbidden"}}"#.utf8), headers: [:])
                == .server(status: 403, message: "Forbidden"))
    }

    @Test func validatesTrackURIs() {
        #expect(SpotifyURI.trackURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC") != nil)
        #expect(SpotifyURI.trackURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC\" to quit") == nil)
        #expect(SpotifyURI.trackURI("spotify:album:4uLU6hMCjMI75M1A2tKUQC") == nil)
        #expect(SpotifyURI.trackURI("spotify:track:short") == nil)
        #expect(SpotifyScripts.playTrackCommand(uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC\"; do shell script \"x") == nil)
        #expect(SpotifyScripts.playTrackCommand(uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.contains("play track \"spotify:track:4uLU6hMCjMI75M1A2tKUQC\"") == true)
    }

    @Test func playsWithinAlbumContextOnlyWhenValid() throws {
        let track = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"
        let withAlbum = try #require(SpotifyScripts.playTrackCommand(uri: track, contextURI: "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4"))
        #expect(withAlbum.contains("play track \"\(track)\" in context \"spotify:album:6N9PS4QXF1D0OWPk0Sxtb4\""))
        let injected = try #require(SpotifyScripts.playTrackCommand(uri: track, contextURI: "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4\" to quit"))
        #expect(!injected.contains("in context"), "invalid context is dropped, not interpolated")
        let result = SpotifyTrackResult(id: "4uLU6hMCjMI75M1A2tKUQC", uri: track, title: "t", artists: [], album: "a", artworkURL: nil, durationMs: nil, albumURI: "spotify:playlist:6N9PS4QXF1D0OWPk0Sxtb4")
        #expect(result.albumURI == nil)
    }

    @Test func appSearchLinkEncodesQuery() {
        #expect(SpotifySearchLinks.appSearchURL(for: " Röyksopp & Robyn ")?.absoluteString == "spotify:search:R%C3%B6yksopp%20%26%20Robyn")
        #expect(SpotifySearchLinks.appSearchURL(for: "  ") == nil)
    }

    @Test func pkceMatchesRFC7636Example() {
        // RFC 7636 Appendix B.
        #expect(SpotifyAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = SpotifyAuth.makeCodeVerifier()
        #expect((43...128).contains(verifier.count))
        #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    }

    @Test func authorizationURLAndCallbackHandling() throws {
        let url = try #require(SpotifyAuth.authorizationURL(clientID: String(repeating: "a", count: 32), redirectURI: "dev.local.nook.staging://spotify-callback", codeChallenge: "abc", state: "xyz"))
        let s = url.absoluteString
        #expect(s.hasPrefix("https://accounts.spotify.com/authorize?"))
        #expect(s.contains("code_challenge_method=S256") && s.contains("response_type=code"))
        #expect(s.contains("scope=user-modify-playback-state"), "exactly the one requested scope")
        #expect(SpotifyAuth.scopes == ["user-modify-playback-state"])
        // Explicit ports: the dashboard rejects port-less loopback URIs ("not secure").
        #expect(SpotifyAuth.redirectURI(bundleIdentifier: "dev.local.nook.staging") == "http://127.0.0.1:43827/nook-callback")
        #expect(SpotifyAuth.redirectURI(bundleIdentifier: "dev.local.nook") == "http://127.0.0.1:43828/nook-callback")
        #expect(SpotifyAuth.redirectURI(port: 53682) == "http://127.0.0.1:53682/nook-callback")

        let good = URL(string: "dev.local.nook.staging://spotify-callback?code=CODE&state=xyz")!
        #expect(try SpotifyAuth.authorizationCode(from: good, expectedState: "xyz") == "CODE")
        let forged = URL(string: "dev.local.nook.staging://spotify-callback?code=CODE&state=other")!
        #expect(throws: SpotifyAPIError.self) { try SpotifyAuth.authorizationCode(from: forged, expectedState: "xyz") }
        let denied = URL(string: "dev.local.nook.staging://spotify-callback?error=access_denied&state=xyz")!
        #expect(throws: SpotifyAPIError.authorizationFailed("access_denied")) { try SpotifyAuth.authorizationCode(from: denied, expectedState: "xyz") }
    }

    @Test func tokenRequestsHaveNoSecretAndParse() throws {
        let req = SpotifyAuth.tokenRequest(code: "c d", verifier: "v", clientID: "id", redirectURI: "a://b")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("code=c%20d") && body.contains("code_verifier=v") && !body.contains("client_secret"))
        #expect(req.httpMethod == "POST")

        let now = Date(timeIntervalSince1970: 1000)
        let token = try SpotifyAuth.parseToken(Data(#"{"access_token":"A","token_type":"Bearer","expires_in":3600,"refresh_token":"R"}"#.utf8), now: now)
        #expect(token == SpotifyToken(accessToken: "A", refreshToken: "R", expiresAt: now.addingTimeInterval(3600)))
        let refreshed = try SpotifyAuth.parseToken(Data(#"{"access_token":"B","expires_in":3600}"#.utf8), now: now, previousRefreshToken: "R")
        #expect(refreshed.refreshToken == "R")
        #expect(token.isExpired(at: now.addingTimeInterval(3550)))
        #expect(!token.isExpired(at: now.addingTimeInterval(100)))
    }

    @Test func tokenScopesAreTracked() throws {
        let now = Date(timeIntervalSince1970: 0)
        let granted = try SpotifyAuth.parseToken(Data(#"{"access_token":"A","expires_in":3600,"scope":"user-modify-playback-state"}"#.utf8), now: now)
        #expect(granted.grants("user-modify-playback-state"))
        let none = try SpotifyAuth.parseToken(Data(#"{"access_token":"A","expires_in":3600,"scope":""}"#.utf8), now: now)
        #expect(!none.grants("user-modify-playback-state"))
        // Tokens saved before scopes were tracked still decode (scope nil → not granted).
        let legacy = try JSONDecoder().decode(SpotifyToken.self, from: Data(#"{"accessToken":"A","expiresAt":0}"#.utf8))
        #expect(legacy.scope == nil && !legacy.grants("user-modify-playback-state"))
    }

    @Test func playInAlbumRequest() throws {
        let request = try #require(SpotifyPlaybackAPI.playInContextRequest(
            trackURI: "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs", contextURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM", accessToken: "tok"))
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://api.spotify.com/v1/me/player/play")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["context_uri"] as? String == "spotify:album:6iyZdOoujtOwiThdAUI8TM")
        #expect((body["offset"] as? [String: Any])?["uri"] as? String == "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs")
        #expect(body["position_ms"] as? Int == 0)
        #expect(body["device_id"] == nil && body["repeat"] == nil && body["shuffle"] == nil, "never touches device choice, repeat or shuffle")
        #expect(SpotifyPlaybackAPI.playInContextRequest(trackURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM", contextURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM", accessToken: "t") == nil)
        #expect(SpotifyPlaybackAPI.reason(from: Data(#"{"error":{"status":403,"message":"x","reason":"PREMIUM_REQUIRED"}}"#.utf8)) == "PREMIUM_REQUIRED")
    }

    @Test func searchPlaybackPlans() {
        let song = SpotifyCatalogItem(id: "1WU8ITnfUP5fI5Ipf1XvNs", uri: "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs", title: "t", artists: ["a"], album: "A",
                                      artworkURL: nil, durationMs: 1, albumURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM")
        // With the scope: Web API, song inside its album (no app activation, album continues).
        #expect(SearchPlaybackPlan.plan(for: song, playbackScopeGranted: true)
                == .webAPI(contextURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM", offsetTrackURI: "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs", fallbackURI: song.uri))
        // Without the scope: the exact song locally, with a reason.
        if case .local(let uri, let reason) = SearchPlaybackPlan.plan(for: song, playbackScopeGranted: false) {
            #expect(uri == song.uri && reason.contains("Sign in"))
        } else { Issue.record("without the scope the exact song should play locally") }
        var noAlbum = song
        noAlbum.albumURI = nil
        if case .local = SearchPlaybackPlan.plan(for: noAlbum, playbackScopeGranted: true) {} else { Issue.record("no album → local") }
        let album = SpotifyCatalogItem(kind: .album, spotifyID: "6iyZdOoujtOwiThdAUI8TM", uri: "spotify:album:6iyZdOoujtOwiThdAUI8TM", title: "A", artists: [], album: "",
                                       artworkURL: nil, durationMs: nil, isPlayable: true, explicit: false, albumURI: nil, year: nil)
        #expect(SearchPlaybackPlan.plan(for: album, playbackScopeGranted: true)
                == .webAPI(contextURI: album.uri, offsetTrackURI: nil, fallbackURI: album.uri))
        let artist = SpotifyCatalogItem(kind: .artist, spotifyID: "4tZwfgrHOc3mvqYlEYSvVi", uri: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi", title: "D", artists: [], album: "",
                                        artworkURL: nil, durationMs: nil, isPlayable: true, explicit: false, albumURI: nil, year: nil)
        #expect(SearchPlaybackPlan.plan(for: artist, playbackScopeGranted: true)
                == .webAPI(contextURI: artist.uri, offsetTrackURI: nil, fallbackURI: artist.uri))
        var bad = song
        bad.uri = "spotify:track:x\" to quit"
        #expect(SearchPlaybackPlan.plan(for: bad, playbackScopeGranted: true) == nil)
    }

    @Test func contextPlayRequests() throws {
        let albumOnly = try #require(SpotifyPlaybackAPI.playRequest(contextURI: "spotify:album:6iyZdOoujtOwiThdAUI8TM", offsetTrackURI: nil, accessToken: "t"))
        let a = try #require(try JSONSerialization.jsonObject(with: albumOnly.httpBody ?? Data()) as? [String: Any])
        #expect(a["context_uri"] as? String == "spotify:album:6iyZdOoujtOwiThdAUI8TM" && a["offset"] == nil)
        let artist = try #require(SpotifyPlaybackAPI.playRequest(contextURI: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi", offsetTrackURI: nil, accessToken: "t"))
        let b = try #require(try JSONSerialization.jsonObject(with: artist.httpBody ?? Data()) as? [String: Any])
        #expect(b["context_uri"] as? String == "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi")
        // An offset only makes sense inside an album; tracks/playlists aren't contexts here.
        #expect(SpotifyPlaybackAPI.playRequest(contextURI: "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi", offsetTrackURI: "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs", accessToken: "t") == nil)
        #expect(SpotifyPlaybackAPI.playRequest(contextURI: "spotify:track:1WU8ITnfUP5fI5Ipf1XvNs", offsetTrackURI: nil, accessToken: "t") == nil)
        #expect(SpotifyPlaybackAPI.playRequest(contextURI: "spotify:playlist:4tZwfgrHOc3mvqYlEYSvVi", offsetTrackURI: nil, accessToken: "t") == nil)
    }

    @Test func clientIDValidationInSettings() {
        var s = NookSettings()
        s.spotifyClientID = "  0123456789ABCDEF0123456789abcdef "
        #expect(s.validated().spotifyClientID == "0123456789abcdef0123456789abcdef")
        s.spotifyClientID = "not-a-client-id"
        #expect(s.validated().spotifyClientID == "")
    }
}

@Suite("Glass appearance & caches")
struct GlassAppearanceTests {
    @Test func resolvesModesFromAccessibilitySettings() {
        let glass = GlassAppearance.resolve(supportsLiquidGlass: true, reduceTransparency: false, reduceMotion: false, increaseContrast: false)
        #expect(glass.mode == .liquidGlass && glass.animatesTransitions && glass.showsAccentGlow && glass.showsSpecularHighlight)

        let older = GlassAppearance.resolve(supportsLiquidGlass: false, reduceTransparency: false, reduceMotion: false, increaseContrast: false)
        #expect(older.mode == .material)

        let solid = GlassAppearance.resolve(supportsLiquidGlass: true, reduceTransparency: true, reduceMotion: true, increaseContrast: false)
        #expect(solid.mode == .opaque && !solid.animatesTransitions && !solid.showsAccentGlow && !solid.showsSpecularHighlight)

        let contrast = GlassAppearance.resolve(supportsLiquidGlass: true, reduceTransparency: false, reduceMotion: false, increaseContrast: true)
        #expect(contrast.borderOpacity > glass.borderOpacity && !contrast.showsAccentGlow)
    }

    @Test func boundedCacheEvictsLeastRecentlyUsed() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.value(for: "a")          // a is now most recent
        cache.insert(3, for: "c")          // evicts b
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1 && cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }
}

@Suite("Spotify play-track script", .enabled(if: NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyScripts.bundleID) != nil))
struct SpotifyPlayTrackScriptTests {
    @Test func compiles() throws {
        for context in [nil, "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4"] {
            let source = try #require(SpotifyScripts.playTrackCommand(uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC", contextURI: context))
            let script = try #require(NSAppleScript(source: source))
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            #expect(compiled, "\(String(describing: error))")
        }
    }
}
