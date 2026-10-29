import Foundation

/// A global keyboard shortcut in Carbon terms (registered with `RegisterEventHotKey`,
/// which needs no Accessibility permission).
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32
    public var enabled: Bool

    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// ⌥⌘N
    public static let `default` = HotKeySpec(keyCode: 45, modifiers: option | command, enabled: true)

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }

    /// A shortcut must include ⌘, ⌃ or ⌥ so it can't hijack plain typing.
    public var isValid: Bool {
        keyCode < 128 && (modifiers & (Self.command | Self.control | Self.option)) != 0
            && (modifiers & ~(Self.command | Self.shift | Self.option | Self.control)) == 0
    }

    public var modifierSymbols: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s
    }
}

public enum ConversationRetention: String, Codable, Sendable, CaseIterable {
    /// Nothing is written to disk; the conversation lives only in memory.
    case memoryOnly
    /// The current conversation is saved locally until cleared or replaced.
    case keepCurrent
}

public enum ModelKeepAlive: String, Codable, Sendable, CaseIterable {
    case unloadImmediately = "0"
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"

    public var label: String {
        switch self {
        case .unloadImmediately: return "Unload after each reply"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes (Ollama default)"
        case .thirtyMinutes: return "30 minutes"
        }
    }
}

public enum NookTab: String, Codable, Sendable, CaseIterable {
    case assistant, music, shelf
}

/// All user settings. Decoding is tolerant (missing or invalid keys fall back to defaults)
/// and every value is clamped by `validated()` when loaded.
public struct NookSettings: Codable, Equatable, Sendable {
    // General
    public var productName = "Nook"
    public var hoverEnabled = true
    public var activationDelay: Double = 0.12
    public var collapseDelay: Double = 0.7
    public var calibration = ActivationCalibration()
    public var hotKey = HotKeySpec.default
    public var reduceMotion = false
    public var showMenuBarIcon = true
    public var showInFullScreenSpaces = true
    public var lastTab: NookTab = .shelf

    // Assistant
    public var ollamaEndpoint = "http://127.0.0.1:11434"
    public var preferredModel = "qwen3:8b"
    public var contextMessageLimit = 20
    public var maxResponseTokens = 2048
    public var contextWindowTokens = 8192
    public var thinkingEnabled = false
    public var keepAlive: ModelKeepAlive = .fiveMinutes
    public var conversationRetention: ConversationRetention = .keepCurrent

    // Music
    public var musicEnabled = true
    public var loadArtwork = true
    public var vinylAnimation = true
    /// Closed notch: album art + animated waves for 2 minutes after the panel closes (while playing).
    public var nowPlayingPeek = true
    public var progressRefreshSeconds: Double = 5
    /// Optional: the user's own Spotify developer app Client ID (public; no secret) for catalogue search.
    public var spotifyClientID = ""

    // Shelf
    public var duplicatePolicy: DuplicatePolicy = .skipIdentical
    public var afterDragOut: AfterDragOutBehavior = .hideRecoverably
    public var recentlyRemovedRetentionDays = 7
    public var cleanup = CleanupPolicy()

    public init() {}

    public static let activationDelayRange: ClosedRange<Double> = 0...1.5
    public static let collapseDelayRange: ClosedRange<Double> = 0.15...5
    public static let contextMessageRange: ClosedRange<Int> = 2...100
    public static let maxResponseTokensRange: ClosedRange<Int> = 128...16_384
    public static let contextWindowRange: ClosedRange<Int> = 2_048...40_960
    public static let refreshRange: ClosedRange<Double> = 2...30
    public static let retentionRange: ClosedRange<Int> = 1...90
    public static let cleanupAgeRange: ClosedRange<Int> = 1...365

    public func validated() -> NookSettings {
        var s = self
        let name = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        s.productName = name.isEmpty ? "Nook" : String(name.prefix(32))
        s.activationDelay = activationDelay.isFinite ? activationDelay.clamped(to: Self.activationDelayRange) : 0.12
        s.collapseDelay = collapseDelay.isFinite ? collapseDelay.clamped(to: Self.collapseDelayRange) : 0.7
        s.calibration = calibration.validated()
        if !hotKey.isValid { s.hotKey = .default }
        if (try? OllamaEndpoint.validate(ollamaEndpoint)) == nil { s.ollamaEndpoint = NookSettings().ollamaEndpoint }
        s.preferredModel = String(preferredModel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if s.preferredModel.isEmpty { s.preferredModel = "qwen3:8b" }
        s.contextMessageLimit = contextMessageLimit.clamped(to: Self.contextMessageRange)
        s.maxResponseTokens = maxResponseTokens.clamped(to: Self.maxResponseTokensRange)
        s.contextWindowTokens = contextWindowTokens.clamped(to: Self.contextWindowRange)
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s.spotifyClientID = SpotifyAuth.isValidClientID(clientID) ? clientID : ""
        s.progressRefreshSeconds = progressRefreshSeconds.isFinite ? progressRefreshSeconds.clamped(to: Self.refreshRange) : 5
        s.recentlyRemovedRetentionDays = recentlyRemovedRetentionDays.clamped(to: Self.retentionRange)
        if let age = cleanup.maxAgeDays { s.cleanup.maxAgeDays = age.clamped(to: Self.cleanupAgeRange) }
        if let bytes = cleanup.maxTotalBytes { s.cleanup.maxTotalBytes = max(bytes, 100 * 1024 * 1024) }
        return s
    }

    // Tolerant decoding: an unknown, missing or malformed key never discards the whole settings blob.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NookSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        productName = v(.productName, d.productName)
        hoverEnabled = v(.hoverEnabled, d.hoverEnabled)
        activationDelay = v(.activationDelay, d.activationDelay)
        collapseDelay = v(.collapseDelay, d.collapseDelay)
        calibration = v(.calibration, d.calibration)
        hotKey = v(.hotKey, d.hotKey)
        reduceMotion = v(.reduceMotion, d.reduceMotion)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        showInFullScreenSpaces = v(.showInFullScreenSpaces, d.showInFullScreenSpaces)
        lastTab = v(.lastTab, d.lastTab)
        ollamaEndpoint = v(.ollamaEndpoint, d.ollamaEndpoint)
        preferredModel = v(.preferredModel, d.preferredModel)
        contextMessageLimit = v(.contextMessageLimit, d.contextMessageLimit)
        maxResponseTokens = v(.maxResponseTokens, d.maxResponseTokens)
        contextWindowTokens = v(.contextWindowTokens, d.contextWindowTokens)
        thinkingEnabled = v(.thinkingEnabled, d.thinkingEnabled)
        keepAlive = v(.keepAlive, d.keepAlive)
        conversationRetention = v(.conversationRetention, d.conversationRetention)
        musicEnabled = v(.musicEnabled, d.musicEnabled)
        loadArtwork = v(.loadArtwork, d.loadArtwork)
        vinylAnimation = v(.vinylAnimation, d.vinylAnimation)
        nowPlayingPeek = v(.nowPlayingPeek, d.nowPlayingPeek)
        progressRefreshSeconds = v(.progressRefreshSeconds, d.progressRefreshSeconds)
        spotifyClientID = v(.spotifyClientID, d.spotifyClientID)
        duplicatePolicy = v(.duplicatePolicy, d.duplicatePolicy)
        afterDragOut = v(.afterDragOut, d.afterDragOut)
        recentlyRemovedRetentionDays = v(.recentlyRemovedRetentionDays, d.recentlyRemovedRetentionDays)
        cleanup = v(.cleanup, d.cleanup)
    }

    public static func decode(_ data: Data?) -> NookSettings {
        guard let data, let decoded = try? JSONDecoder().decode(NookSettings.self, from: data) else {
            return NookSettings()
        }
        return decoded.validated()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
