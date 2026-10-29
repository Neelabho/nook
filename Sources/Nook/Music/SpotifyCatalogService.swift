import AppKit
import NookCore
import Observation
import Security

/// Optional Spotify catalogue search via the official Web API.
///
/// - Uses the user's *own* Spotify developer app (Client ID only; PKCE, no client secret).
/// - Spotify accepts only HTTPS or loopback-IP redirect URIs, so sign-in uses the RFC 8252 loopback
///   pattern: the default browser shows Spotify's sign-in page, and Nook listens on 127.0.0.1 (random
///   port) for that single redirect, then closes the listener (success, failure, or after 5 minutes).
///   This needs the sandbox `network.server` entitlement, which is only added to builds made with NOOK_ALLOW_LOOPBACK_SIGNIN=1.
/// - Requests no scopes (search doesn't need any). Tokens live in the Keychain, per bundle identifier,
///   so staging and production never share them.
/// - Makes requests only when the user searches.
@MainActor
@Observable
final class SpotifyCatalogService {
    enum AuthState: Equatable {
        case notConfigured
        case signedOut
        case signingIn
        case signedIn
        case error(String)
    }

    private(set) var authState: AuthState = .notConfigured
    /// Whether the stored sign-in includes `user-modify-playback-state` (play a song inside its album).
    private(set) var playbackScopeGranted = false
    /// Shown in the search panel when a song had to play on its own (and why).
    var playbackNote: String?

    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private let diagnostics: DiagnosticsService
    @ObservationIgnored private var token: SpotifyToken?
    @ObservationIgnored private var receiver: LoopbackRedirectReceiver?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<SpotifyToken, Error>?
    @ObservationIgnored private let urlSession: URLSession = {
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
        reloadState()
    }

    var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "dev.local.nook" }
    /// Exactly what to register in the Spotify dashboard (fixed port; differs for staging/production).
    var redirectURI: String { SpotifyAuth.redirectURI(bundleIdentifier: bundleIdentifier) }
    private var callbackPort: UInt16 { SpotifyAuth.callbackPort(bundleIdentifier: bundleIdentifier) }

    /// Whether this build may open the temporary loopback listener sign-in needs.
    var loopbackSignInEnabled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.server" as CFString, nil) else { return false }
        return (value as? Bool) == true
    }
    private var clientID: String { settings.settings.spotifyClientID }
    private var keychainService: String { "\(bundleIdentifier).spotify-web-api" }

    /// Re-reads configuration and the stored token (e.g. after the Client ID changes).
    func reloadState() {
        guard !clientID.isEmpty else {
            token = nil
            authState = .notConfigured
            return
        }
        // Read the Keychain off the main thread: after a rebuild macOS may show an access dialog, and
        // waiting for it on the main thread froze Nook (and left signal handlers uninstalled).
        let service = keychainService
        let account = clientID
        loadTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { Keychain.load(service: service, account: account) }.value
            guard let self, self.clientID == account else { return }
            self.token = data.flatMap { try? JSONDecoder().decode(SpotifyToken.self, from: $0) }
            self.authState = self.token == nil ? .signedOut : .signedIn
            self.playbackScopeGranted = self.token?.grants(SpotifyAuth.playbackScope) ?? false
        }
    }

    /// Completes once the stored sign-in has been read (used by self-tests).
    func waitUntilLoaded() async { await loadTask?.value }

    /// Why catalogue search can't run right now, or nil when it can.
    func configurationProblem() -> SpotifyAPIError? {
        switch authState {
        case .notConfigured: return .notConfigured
        case .signedOut, .signingIn, .error: return .notSignedIn
        case .signedIn: return nil
        }
    }

    // MARK: Sign-in

    func signIn() {
        guard !clientID.isEmpty else { authState = .notConfigured; return }
        guard loopbackSignInEnabled else {
            authState = .error("This build can't receive Spotify's sign-in redirect (the 127.0.0.1 sign-in listener isn't enabled). See docs: Spotify search setup.")
            return
        }
        receiver?.stop()
        let receiver = LoopbackRedirectReceiver()
        self.receiver = receiver
        let verifier = SpotifyAuth.makeCodeVerifier()
        let state = UUID().uuidString
        let clientID = self.clientID
        let callbackPort = self.callbackPort
        authState = .signingIn

        Task { [weak self] in
            do {
                let port = try await receiver.start(port: callbackPort)
                let redirect = SpotifyAuth.redirectURI(port: port)
                guard let url = SpotifyAuth.authorizationURL(clientID: clientID, redirectURI: redirect,
                                                             codeChallenge: SpotifyAuth.codeChallenge(for: verifier), state: state) else {
                    throw SpotifyAPIError.authorizationFailed("couldn't prepare the sign-in page")
                }
                NSWorkspace.shared.open(url)    // the user's default browser, on accounts.spotify.com
                let callback = try await receiver.nextCallback(timeout: .seconds(300))
                let code: String
                do {
                    code = try SpotifyAuth.authorizationCode(from: callback, expectedState: state)
                    receiver.respond(success: true)
                } catch {
                    receiver.respond(success: false)
                    throw error
                }
                guard let self else { return }
                let token = try await self.exchange(
                    SpotifyAuth.tokenRequest(code: code, verifier: verifier, clientID: clientID, redirectURI: redirect),
                    previousRefresh: nil)
                self.store(token)
                self.authState = .signedIn
                self.diagnostics.record("music", "Signed in to Spotify Web API")
            } catch {
                receiver.stop()
                guard let self, self.receiver === receiver else { return }
                self.authState = .error((error as? LocalizedError)?.errorDescription ?? "Sign-in failed.")
            }
            if self?.receiver === receiver { self?.receiver = nil }
        }
    }

    func signOut() {
        receiver?.stop()
        receiver = nil
        if !clientID.isEmpty { Keychain.delete(service: keychainService, account: clientID) }
        token = nil
        authState = clientID.isEmpty ? .notConfigured : .signedOut
    }

    /// Removes a stored token for a Client ID that is no longer configured.
    func forgetToken(for oldClientID: String) {
        guard !oldClientID.isEmpty else { return }
        Keychain.delete(service: keychainService, account: oldClientID)
    }

    // MARK: Tokens

    private func store(_ token: SpotifyToken) {
        var token = token
        if token.scope == nil { token.scope = self.token?.scope }   // refresh responses may omit scope
        self.token = token
        playbackScopeGranted = token.grants(SpotifyAuth.playbackScope)
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, service: keychainService, account: clientID)
        }
    }

    private func exchange(_ request: URLRequest, previousRefresh: String?) async throws -> SpotifyToken {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SpotifyAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.malformedResponse }
        guard http.statusCode == 200 else {
            throw http.statusCode == 400 ? SpotifyAPIError.unauthorized : SpotifyAPIError.from(status: http.statusCode, data: data, headers: http.allHeaderFields)
        }
        return try SpotifyAuth.parseToken(data, now: Date(), previousRefreshToken: previousRefresh)
    }

    /// A valid access token, refreshing it (once, shared) when expired.
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard !clientID.isEmpty else { throw SpotifyAPIError.notConfigured }
        guard let current = token else { throw SpotifyAPIError.notSignedIn }
        if !forceRefresh && !current.isExpired(at: Date()) { return current.accessToken }
        guard let refresh = current.refreshToken else { signOut(); throw SpotifyAPIError.unauthorized }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await exchange(SpotifyAuth.refreshRequest(refreshToken: refresh, clientID: clientID), previousRefresh: refresh) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            store(renewed)
            return renewed.accessToken
        } catch SpotifyAPIError.unauthorized {
            signOut()
            throw SpotifyAPIError.unauthorized
        }
    }

    // MARK: Playback (Web API)

    enum PlaybackFailure: LocalizedError, Equatable {
        case noActiveDevice
        case premiumRequired
        case permissionMissing
        case other(String)

        var errorDescription: String? {
            switch self {
            case .noActiveDevice: return "Spotify on this Mac isn't the active device"
            case .premiumRequired: return "Spotify Premium is required to start playback this way"
            case .permissionMissing: return "sign in again to allow playback"
            case .other(let message): return message
            }
        }
    }

    /// Plays a context (album/artist), optionally starting at a track, on the active device.
    func play(contextURI: String, offsetTrackURI: String?) async throws {
        var attempt = 0
        while true {
            let token: String
            do { token = try await accessToken(forceRefresh: attempt > 0) }
            catch { throw PlaybackFailure.other((error as? LocalizedError)?.errorDescription ?? "not signed in") }
            guard let request = SpotifyPlaybackAPI.playRequest(contextURI: contextURI, offsetTrackURI: offsetTrackURI, accessToken: token) else {
                throw PlaybackFailure.other("invalid Spotify item")
            }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                throw PlaybackFailure.other("couldn't reach Spotify (\(error.localizedDescription))")
            }
            guard let http = response as? HTTPURLResponse else { throw PlaybackFailure.other("unreadable response") }
            if http.statusCode == 401 && attempt == 0 { attempt += 1; continue }
            if (200...299).contains(http.statusCode) { return }
            switch SpotifyPlaybackAPI.reason(from: data) {
            case "NO_ACTIVE_DEVICE": throw PlaybackFailure.noActiveDevice
            case "PREMIUM_REQUIRED": throw PlaybackFailure.premiumRequired
            default:
                if http.statusCode == 404 { throw PlaybackFailure.noActiveDevice }
                if http.statusCode == 403 && !playbackScopeGranted { throw PlaybackFailure.permissionMissing }
                throw PlaybackFailure.other(SpotifyAPIError.from(status: http.statusCode, data: data, headers: http.allHeaderFields).errorDescription ?? "Spotify error \(http.statusCode)")
            }
        }
    }

    func playInAlbum(trackURI: String, albumURI: String) async throws {
        try await play(contextURI: albumURI, offsetTrackURI: trackURI)
    }

    // MARK: Search

    /// Market used for search. An explicit country from the Mac's region avoids needing the
    /// `user-read-private` scope that `from_token` requires.
    var searchMarket: SpotifySearchAPI.Market = .country(fromRegion: Locale.current.region?.identifier)

    func search(_ query: String) async throws -> [SpotifyTrackResult] {
        try await search(query, market: searchMarket)
    }

    func search(_ query: String, market: SpotifySearchAPI.Market) async throws -> [SpotifyTrackResult] {
        var attempt = 0
        while true {
            let token = try await accessToken(forceRefresh: attempt > 0)
            guard let request = SpotifySearchAPI.request(query: query, accessToken: token, market: market) else { return [] }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw SpotifyAPIError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.malformedResponse }
            if http.statusCode == 401 && attempt == 0 { attempt += 1; continue }   // expired early: refresh once
            guard http.statusCode == 200 else { throw SpotifyAPIError.from(status: http.statusCode, data: data, headers: http.allHeaderFields) }
            return try SpotifySearchAPI.parse(data)
        }
    }
}

/// Minimal generic-password Keychain wrapper (login keychain).
enum Keychain {
    static func save(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(update) { $1 }
            add[kSecAttrLabel as String] = "Nook — Spotify sign-in"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Status of a read attempt (diagnostics only; never returns the secret).
    static func probe(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        result = nil
        return status
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
