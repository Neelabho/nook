import CryptoKit
import Foundation

// MARK: - Search results

/// One catalogue result: a track, artist or album.
public struct SpotifyCatalogItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case track, artist, album
    }

    public var kind: Kind
    /// Spotify's 22-character ID.
    public var spotifyID: String
    /// `spotify:<kind>:<id>` (validated). Also the stable identity, unique across kinds.
    public var uri: String
    public var title: String
    public var artists: [String]
    /// Album name (tracks) — empty for artists and albums.
    public var album: String
    public var artworkURL: URL?
    public var durationMs: Int?
    /// `false` when Spotify reports the item can't be played in the user's market.
    public var isPlayable: Bool
    public var explicit: Bool
    /// For tracks: `spotify:album:<id>`, played as the context so Next/Previous continue through the album.
    public var albumURI: String?
    /// For albums: release year.
    public var year: String?

    public var id: String { uri }

    /// Track initializer.
    public init(id: String, uri: String, title: String, artists: [String], album: String, artworkURL: URL?, durationMs: Int?,
                isPlayable: Bool = true, explicit: Bool = false, albumURI: String? = nil) {
        self.init(kind: .track, spotifyID: id, uri: uri, title: title, artists: artists, album: album, artworkURL: artworkURL,
                  durationMs: durationMs, isPlayable: isPlayable, explicit: explicit, albumURI: albumURI, year: nil)
    }

    public init(kind: Kind, spotifyID: String, uri: String, title: String, artists: [String], album: String, artworkURL: URL?,
                durationMs: Int?, isPlayable: Bool, explicit: Bool, albumURI: String?, year: String?) {
        self.kind = kind
        self.spotifyID = spotifyID
        self.uri = uri
        self.title = title
        self.artists = artists
        self.album = album
        self.artworkURL = artworkURL
        self.durationMs = durationMs
        self.isPlayable = isPlayable
        self.explicit = explicit
        self.albumURI = albumURI.flatMap(SpotifyURI.albumURI)
        self.year = year
    }

    public var artistLine: String { artists.joined(separator: ", ") }

    /// Secondary line shown under the title.
    public var subtitle: String {
        switch kind {
        case .track: return [artistLine, album].filter { !$0.isEmpty }.joined(separator: " · ")
        case .artist: return "Artist"
        case .album: return (["Album", artistLine, year ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

/// Kept for source compatibility: tracks are catalogue items of kind `.track`.
public typealias SpotifyTrackResult = SpotifyCatalogItem

public enum SpotifyURI {
    /// Spotify IDs are 22 base-62 characters.
    public static func isValidTrackID(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `spotify:track:<id>` when valid; nil otherwise.
    public static func trackURI(_ uri: String) -> String? { validated(uri, kind: "track") }

    /// `spotify:album:<id>` when valid; nil otherwise.
    public static func albumURI(_ uri: String) -> String? { validated(uri, kind: "album") }

    /// A playable track, album or artist URI — the only forms ever placed into an AppleScript.
    public static func playableURI(_ uri: String) -> String? {
        validated(uri, kind: "track") ?? validated(uri, kind: "album") ?? validated(uri, kind: "artist")
    }

    static func validated(_ uri: String, kind: String) -> String? {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == kind, isValidTrackID(String(parts[2])) else { return nil }
        return uri
    }
}

public enum SpotifySearchLinks {
    /// Opens the Spotify app's own search (full catalogue, shown in Spotify). Needs no account setup.
    public static func appSearchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = trimmed.prefix(200).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }
}

// MARK: - Errors

public enum SpotifyAPIError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case notSignedIn
    case unauthorized
    case rateLimited(retryAfter: Int?)
    case quotaExceeded
    case server(status: Int, message: String)
    case malformedResponse
    case network(String)
    case authorizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Catalogue search needs a one-time Spotify setup in Settings › Music."
        case .notSignedIn: return "Sign in to Spotify in Settings › Music to search the catalogue."
        case .unauthorized: return "Spotify sign-in expired. Sign in again in Settings › Music."
        case .rateLimited(let seconds): return "Spotify is limiting requests. Try again\(seconds.map { " in \($0)s" } ?? " shortly")."
        case .quotaExceeded: return "Your Spotify developer app has used its request quota. Try again later."
        case .server(let status, let message): return "Spotify returned an error (\(status))\(message.isEmpty ? "" : ": \(message)")."
        case .malformedResponse: return "Spotify sent a response Nook couldn't read."
        case .network(let message): return "Couldn't reach Spotify: \(message)"
        case .authorizationFailed(let message): return "Spotify sign-in failed: \(message)"
        }
    }

    public static func from(status: Int, data: Data, headers: [AnyHashable: Any]) -> SpotifyAPIError {
        switch status {
        case 401: return .unauthorized
        case 429:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (json?["reason"] as? String) == "QUOTA_EXCEEDED" { return .quotaExceeded }
            let retry = (headers["Retry-After"] as? String).flatMap(Int.init) ?? (headers["retry-after"] as? String).flatMap(Int.init)
            return .rateLimited(retryAfter: retry)
        default:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error_description"] as? String)
                ?? (json?["error"] as? String) ?? ""
            return .server(status: status, message: String(message.prefix(200)))
        }
    }
}

// MARK: - Search request / response

public enum SpotifySearchAPI {
    public static let endpoint = URL(string: "https://api.spotify.com/v1/search")!
    public static let maxQueryLength = 200

    /// Spotify caps `limit` at 10 per type (Development Mode changes, February 2026).
    public static let maxLimit = 10

    /// Which market to filter results by.
    public enum Market: Equatable, Sendable {
        /// No market parameter.
        case none
        /// An ISO 3166-1 alpha-2 country code (e.g. from the Mac's region setting).
        case country(String)
        /// `from_token`: the account's country. Needs the `user-read-private` scope ("Insufficient client
        /// scope" otherwise, observed 2026-10-24).
        case fromToken

        public static func country(fromRegion region: String?) -> Market {
            guard let region, region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }) else { return .none }
            return .country(region.uppercased())
        }
    }

    /// Builds `GET /v1/search?type=track,artist,album`. Returns nil for an empty query.
    public static func request(query: String, accessToken: String, limit: Int = 6, types: [SpotifyCatalogItem.Kind] = [.track, .artist, .album], market: Market = .none) -> URLRequest? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accessToken.isEmpty else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: String(trimmed.prefix(maxQueryLength))),
            URLQueryItem(name: "type", value: types.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), maxLimit))),
        ]
        switch market {
        case .none: break
        case .country(let code): components?.queryItems?.append(URLQueryItem(name: "market", value: code))
        case .fromToken: components?.queryItems?.append(URLQueryItem(name: "market", value: "from_token"))
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    /// Parses tracks, then artists, then albums (whichever sections are present).
    public static func parse(_ data: Data) throws -> [SpotifyCatalogItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpotifyAPIError.malformedResponse }
        let sections = ["tracks", "artists", "albums"].compactMap { (json[$0] as? [String: Any])?["items"] as? [Any] }
        guard !sections.isEmpty else { throw SpotifyAPIError.malformedResponse }
        func items(_ key: String) -> [[String: Any]] {
            ((json[key] as? [String: Any])?["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        func names(_ value: Any?) -> [String] { (value as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [] }

        let tracks: [SpotifyCatalogItem] = items("tracks").compactMap { item in
            guard let id = item["id"] as? String, SpotifyURI.isValidTrackID(id), let name = item["name"] as? String else { return nil }
            let album = item["album"] as? [String: Any]
            return SpotifyCatalogItem(
                id: id, uri: "spotify:track:\(id)", title: name, artists: names(item["artists"]),
                album: album?["name"] as? String ?? "",
                artworkURL: bestArtwork((album?["images"] as? [[String: Any]]) ?? [], minimumPixels: 64),
                durationMs: (item["duration_ms"] as? NSNumber)?.intValue,
                isPlayable: (item["is_playable"] as? Bool) ?? true,
                explicit: (item["explicit"] as? Bool) ?? false,
                albumURI: album?["uri"] as? String
            )
        }
        let artists: [SpotifyCatalogItem] = items("artists").compactMap { item in
            guard let id = item["id"] as? String, SpotifyURI.isValidTrackID(id), let name = item["name"] as? String else { return nil }
            return SpotifyCatalogItem(kind: .artist, spotifyID: id, uri: "spotify:artist:\(id)", title: name, artists: [], album: "",
                                      artworkURL: bestArtwork((item["images"] as? [[String: Any]]) ?? [], minimumPixels: 64),
                                      durationMs: nil, isPlayable: true, explicit: false, albumURI: nil, year: nil)
        }
        let albums: [SpotifyCatalogItem] = items("albums").compactMap { item in
            guard let id = item["id"] as? String, SpotifyURI.isValidTrackID(id), let name = item["name"] as? String else { return nil }
            let year = (item["release_date"] as? String).map { String($0.prefix(4)) }
            return SpotifyCatalogItem(kind: .album, spotifyID: id, uri: "spotify:album:\(id)", title: name, artists: names(item["artists"]), album: "",
                                      artworkURL: bestArtwork((item["images"] as? [[String: Any]]) ?? [], minimumPixels: 64),
                                      durationMs: nil, isPlayable: true, explicit: false, albumURI: nil, year: year)
        }
        return tracks + artists + albums
    }

    /// The smallest image at least `minimumPixels` wide (thumbnails), restricted to Spotify's CDN.
    static func bestArtwork(_ images: [[String: Any]], minimumPixels: Int) -> URL? {
        let candidates: [(Int, URL)] = images.compactMap { image in
            guard let s = image["url"] as? String, let url = ArtworkURLPolicy.validated(s) else { return nil }
            return ((image["width"] as? NSNumber)?.intValue ?? 0, url)
        }
        let sorted = candidates.sorted { $0.0 < $1.0 }
        return (sorted.first { $0.0 >= minimumPixels } ?? sorted.last)?.1
    }
}

// MARK: - Playback (Web API)

public enum SpotifyPlaybackAPI {
    public static let playEndpoint = URL(string: "https://api.spotify.com/v1/me/player/play")!

    /// `PUT /v1/me/player/play` for a context (album or artist), optionally starting at a track
    /// within it. No device is named (the active device plays), and repeat/shuffle are never sent.
    public static func playRequest(contextURI: String, offsetTrackURI: String?, accessToken: String) -> URLRequest? {
        guard !accessToken.isEmpty,
              let context = SpotifyURI.albumURI(contextURI) ?? SpotifyURI.validated(contextURI, kind: "artist") else { return nil }
        var body: [String: Any] = ["context_uri": context]
        if let offsetTrackURI {
            guard let track = SpotifyURI.trackURI(offsetTrackURI), SpotifyURI.albumURI(context) != nil else { return nil }
            body["offset"] = ["uri": track]
            body["position_ms"] = 0
        }
        var request = URLRequest(url: playEndpoint)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 10
        return request
    }

    public static func playInContextRequest(trackURI: String, contextURI: String, accessToken: String) -> URLRequest? {
        guard SpotifyURI.trackURI(trackURI) != nil, SpotifyURI.albumURI(contextURI) != nil else { return nil }
        return playRequest(contextURI: contextURI, offsetTrackURI: trackURI, accessToken: accessToken)
    }

    /// Spotify's player errors carry a `reason` (e.g. PREMIUM_REQUIRED, NO_ACTIVE_DEVICE).
    public static func reason(from data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error"] as? [String: Any])?["reason"] as? String
    }
}

/// How a catalogue item gets played, decided without side effects so it can be unit-tested.
///
/// The Web API is preferred: it plays without bringing the Spotify app to the front (verified
/// 2026-10-24; AppleScript `play track` makes Spotify frontmost) and sets a real context, so a song
/// continues through its album instead of looping with Repeat on.
public enum SearchPlaybackPlan: Equatable, Sendable {
    /// Web API: play `contextURI` (album/artist), starting at `offsetTrackURI` when given.
    case webAPI(contextURI: String, offsetTrackURI: String?, fallbackURI: String)
    /// AppleScript `play track` (brings Spotify forward; a song plays on its own). Used when the Web
    /// API can't be (no playback permission, or no album for the song).
    case local(uri: String, reason: String)

    public static func plan(for item: SpotifyCatalogItem, playbackScopeGranted: Bool) -> SearchPlaybackPlan? {
        guard let uri = SpotifyURI.playableURI(item.uri) else { return nil }
        guard playbackScopeGranted else {
            return .local(uri: uri, reason: "Sign in to Spotify again (Settings › Music) to play without opening Spotify and to keep albums queued.")
        }
        switch item.kind {
        case .album, .artist:
            return .webAPI(contextURI: uri, offsetTrackURI: nil, fallbackURI: uri)
        case .track:
            guard let album = item.albumURI else { return .local(uri: uri, reason: "Spotify didn't report this song's album.") }
            return .webAPI(contextURI: album, offsetTrackURI: uri, fallbackURI: uri)
        }
    }
}

// MARK: - Loopback redirect handling (RFC 8252)

public enum LoopbackCallback {
    /// Parses the first request line ("GET /nook-callback?code=…&state=… HTTP/1.1") into a URL.
    /// Returns nil for anything that isn't a GET to the callback path.
    public static func callbackURL(fromRequest data: Data, port: UInt16) -> URL? {
        guard let text = String(data: data.prefix(8192), encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              parts[1].hasPrefix("/nook-callback") else { return nil }
        let pathAndQuery = String(parts[1])
        let afterPath = pathAndQuery.dropFirst("/nook-callback".count)
        guard afterPath.isEmpty || afterPath.hasPrefix("?") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")
    }

    /// A minimal, self-contained page (no external resources) shown in the browser after sign-in.
    public static func response(success: Bool) -> Data {
        let message = success ? "Signed in to Spotify. You can close this tab and return to Nook."
                              : "Spotify sign-in didn't complete. You can close this tab and try again from Nook's settings."
        let body = "<!doctype html><meta charset=utf-8><title>Nook</title><body style=\"font:15px -apple-system;background:#111;color:#eee;display:grid;place-items:center;height:90vh\"><p>\(message)</p>"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}

// MARK: - OAuth (Authorization Code with PKCE; no client secret)

public struct SpotifyToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// Space-separated scopes Spotify actually granted (nil for tokens saved before scopes were tracked).
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public func grants(_ scope: String) -> Bool {
        (self.scope ?? "").split(separator: " ").contains { $0 == scope }
    }

    public func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

public enum SpotifyAuth {
    public static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    /// Search needs no scope. `user-modify-playback-state` lets Nook start a
    /// chosen song *within its album* via the Web API; AppleScript can't do that correctly.
    public static let playbackScope = "user-modify-playback-state"
    public static let scopes: [String] = [playbackScope]

    /// Client IDs from the Spotify developer dashboard are 32 hex characters.
    public static func isValidClientID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit }
    }

    /// Spotify only accepts HTTPS or loopback-IP redirect URIs (custom schemes and `localhost` are
    /// rejected), so a desktop app uses the RFC 8252 loopback pattern.
    ///
    /// Spotify's docs say a loopback URI may be registered without a port, but the dashboard rejects
    /// that form ("This redirect URI is not secure", observed 2026-10-24). So Nook uses a fixed,
    /// explicit port, different for staging and production.
    public static func callbackPort(bundleIdentifier: String) -> UInt16 {
        bundleIdentifier.hasSuffix(".staging") ? 43827 : 43828
    }

    /// Exactly what to register in the Spotify dashboard, and what Nook sends.
    public static func redirectURI(bundleIdentifier: String) -> String {
        redirectURI(port: callbackPort(bundleIdentifier: bundleIdentifier))
    }

    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/nook-callback" }

    public static func makeCodeVerifier(byteCount: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func authorizationURL(clientID: String, redirectURI: String, codeChallenge: String, state: String) -> URL? {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "state", value: state),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        components?.queryItems = items
        return components?.url
    }

    /// Extracts the code from the callback, verifying `state` (CSRF protection).
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw SpotifyAPIError.authorizationFailed(error) }
        guard value("state") == expectedState else { throw SpotifyAPIError.authorizationFailed("state mismatch") }
        guard let code = value("code"), !code.isEmpty else { throw SpotifyAPIError.authorizationFailed("no code returned") }
        return code
    }

    public static func tokenRequest(code: String, verifier: String, clientID: String, redirectURI: String) -> URLRequest {
        formRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }

    static func formRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.timeoutInterval = 15
        return request
    }

    /// Parses a token response. Spotify may omit `refresh_token` on refresh; the previous one is kept.
    public static func parseToken(_ data: Data, now: Date, previousRefreshToken: String? = nil) throws -> SpotifyToken {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw SpotifyAPIError.malformedResponse
        }
        return SpotifyToken(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? previousRefreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            scope: json["scope"] as? String
        )
    }
}
