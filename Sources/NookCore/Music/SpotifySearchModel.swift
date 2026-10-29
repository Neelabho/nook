import Foundation
import Observation

public enum SpotifySearchPhase: Equatable, Sendable {
    /// Nothing typed yet (or cleared).
    case idle
    /// Catalogue search isn't set up; the UI offers "Search in Spotify app" instead.
    case needsSetup(String)
    case searching(query: String)
    case results(query: String)
    case noResults(query: String)
    case failed(String)
}

public enum PlaybackRequestState: Equatable, Sendable {
    case none
    case starting(trackID: String)
    case started(trackID: String)
    case failed(trackID: String, message: String)
}

/// Debounced Spotify catalogue search. Typing never plays anything; only `play(_:)` (an explicit
/// click or Return on a highlighted row) starts playback.
@MainActor
@Observable
public final class SpotifySearchModel {
    public static let minimumQueryLength = 2

    public var query: String = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    public private(set) var phase: SpotifySearchPhase = .idle
    public private(set) var results: [SpotifyTrackResult] = []
    /// Keyboard highlight; nil until the user moves into the list.
    public private(set) var highlightedIndex: Int?
    public private(set) var playback: PlaybackRequestState = .none
    /// Number of requests actually sent (for tests/diagnostics).
    public private(set) var requestCount = 0

    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let search: @Sendable (String) async throws -> [SpotifyTrackResult]
    @ObservationIgnored private let playTrack: @MainActor (SpotifyTrackResult) async throws -> Void
    @ObservationIgnored private let configuration: @MainActor () -> SpotifyAPIError?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// - Parameter configuration: returns why search can't run (not configured / not signed in), or nil if ready.
    public init(
        debounce: Duration = .milliseconds(350),
        configuration: @escaping @MainActor () -> SpotifyAPIError? = { nil },
        search: @escaping @Sendable (String) async throws -> [SpotifyTrackResult],
        play: @escaping @MainActor (SpotifyTrackResult) async throws -> Void
    ) {
        self.debounce = debounce
        self.configuration = configuration
        self.search = search
        self.playTrack = play
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func queryChanged() {
        highlightedIndex = nil
        schedule(after: debounce)
    }

    /// Return in the search field: search now, or play the highlighted row if the user arrowed into the list.
    public func submit() {
        if let index = highlightedIndex, results.indices.contains(index) {
            play(results[index])
        } else {
            schedule(after: .zero)
        }
    }

    public func clear() {
        pending?.cancel()
        generation += 1
        query = ""
        results = []
        highlightedIndex = nil
        phase = .idle
    }

    /// Stops any in-flight search (e.g. when the search UI closes).
    public func cancel() {
        pending?.cancel()
        generation += 1
        if case .searching = phase { phase = results.isEmpty ? .idle : .results(query: trimmedQuery) }
    }

    public func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = highlightedIndex ?? (delta > 0 ? -1 : results.count)
        highlightedIndex = min(max(current + delta, 0), results.count - 1)
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        generation += 1
        let token = generation
        let text = trimmedQuery
        guard text.count >= Self.minimumQueryLength else {
            results = []
            phase = .idle
            return
        }
        if let problem = configuration() {
            results = []
            phase = .needsSetup(problem.errorDescription ?? "Catalogue search isn't set up.")
            return
        }
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.perform(text, token: token)
        }
    }

    private func perform(_ text: String, token: Int) async {
        phase = .searching(query: text)
        requestCount += 1
        do {
            let found = try await search(text)
            // Ignore stale responses: the query changed (or was cleared) while this was in flight.
            guard token == generation, !Task.isCancelled else { return }
            results = found
            phase = found.isEmpty ? .noResults(query: text) : .results(query: text)
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            results = []
            if let api = error as? SpotifyAPIError, api == .notConfigured || api == .notSignedIn || api == .unauthorized {
                phase = .needsSetup(api.errorDescription ?? "")
            } else {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Search failed.")
            }
        }
    }

    /// Explicit user action only.
    public func play(_ result: SpotifyTrackResult) {
        guard result.isPlayable else {
            playback = .failed(trackID: result.id, message: "This track isn't available to play in your region.")
            return
        }
        guard SpotifyURI.playableURI(result.uri) != nil else {
            playback = .failed(trackID: result.id, message: "Invalid Spotify item.")
            return
        }
        playback = .starting(trackID: result.id)
        Task { [weak self] in
            do {
                try await self?.playTrack(result)
                self?.playback = .started(trackID: result.id)
            } catch {
                self?.playback = .failed(trackID: result.id, message: (error as? LocalizedError)?.errorDescription ?? "Couldn't start playback.")
            }
        }
    }
}
