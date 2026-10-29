import AppKit
import NookCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, assistant, music, shelf, privacy, diagnostics
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .assistant: return "sparkles"
        case .music: return "music.note"
        case .shelf: return "tray.full"
        case .privacy: return "hand.raised"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let env: AppEnvironment
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    init(env: AppEnvironment) {
        self.env = env
    }

    func show(tab: SettingsTab) {
        navigation.tab = tab
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(env: env, navigation: navigation))
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(env.settings.settings.productName) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.identifier = NSUserInterfaceItemIdentifier("NookSettings")
            window.appearance = NSAppearance(named: .darkAqua)   // same dark language as the panel
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 640, height: 560))
            window.center()
            self.window = window
        }
        env.loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the view hierarchy (and anything it observes) while Settings is closed.
        window?.contentViewController = nil
        window = nil
    }
}

struct SettingsRootView: View {
    let env: AppEnvironment
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(env: env).tabItem { Label("General", systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            AssistantSettings(env: env).tabItem { Label("Assistant", systemImage: SettingsTab.assistant.symbol) }.tag(SettingsTab.assistant)
            MusicSettings(env: env).tabItem { Label("Music", systemImage: SettingsTab.music.symbol) }.tag(SettingsTab.music)
            ShelfSettings(env: env).tabItem { Label("Shelf", systemImage: SettingsTab.shelf.symbol) }.tag(SettingsTab.shelf)
            PrivacySettings(env: env).tabItem { Label("Privacy", systemImage: SettingsTab.privacy.symbol) }.tag(SettingsTab.privacy)
            DiagnosticsSettings(env: env).tabItem { Label("Diagnostics", systemImage: SettingsTab.diagnostics.symbol) }.tag(SettingsTab.diagnostics)
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }
}

/// A plain, bordered text box for Settings forms. In macOS's grouped Form style a `TextField`'s title
/// becomes the row label and the input turns into a borderless trailing area, which collapsed to
/// almost nothing beside a button (reported: "no text box to enter data"). Hiding the label and
/// using a rounded-border field with a minimum width keeps the input obvious and clickable.
struct SettingsTextField: View {
    let prompt: String
    @Binding var text: String
    var monospaced = false
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .body.monospaced() : .body)
            .frame(minWidth: 280, maxWidth: .infinity)
            .onSubmit(onSubmit)
            .accessibilityLabel(prompt)
    }
}

// MARK: General

struct GeneralSettings: View {
    let env: AppEnvironment
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let s = env.settings
        Form {
            Section("Startup") {
                Toggle("Open Nook at login", isOn: Binding(get: { env.loginItem.isEnabled || env.loginItem.needsApproval },
                                                            set: { env.loginItem.setEnabled($0) }))
                Text(env.loginItem.statusText).font(.caption).foregroundStyle(.secondary)
                if env.loginItem.needsApproval {
                    Button("Open Login Items Settings…") { env.loginItem.openSystemSettings() }
                }
                if let error = env.loginItem.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle("Show menu bar icon", isOn: s.binding(\.showMenuBarIcon))
                if !s.settings.showMenuBarIcon {
                    Text("To get back to Settings without the icon, use the shortcut and the gear button, or open Nook again from Finder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notch") {
                Toggle("Open when the pointer rests on the notch", isOn: s.binding(\.hoverEnabled))
                LabeledSlider(title: "Open delay", value: s.binding(\.activationDelay), range: NookSettings.activationDelayRange, format: "%.2f s")
                LabeledSlider(title: "Close delay", value: s.binding(\.collapseDelay), range: NookSettings.collapseDelayRange, format: "%.2f s")
                Toggle("Available in full-screen apps", isOn: s.binding(\.showInFullScreenSpaces))
                Toggle("Reduce motion", isOn: s.binding(\.reduceMotion))
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("Reduce Motion is on in System Settings, so animations are already minimized.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Activation area calibration") {
                LabeledSlider(title: "Extra width", value: s.binding(\.calibration.extraWidth), range: ActivationCalibration.extraWidthRange, format: "%.0f pt")
                LabeledSlider(title: "Height (0 = notch)", value: s.binding(\.calibration.height), range: ActivationCalibration.heightRange, format: "%.0f pt")
                LabeledSlider(title: "Horizontal offset", value: s.binding(\.calibration.horizontalOffset), range: ActivationCalibration.offsetRange, format: "%.0f pt")
                HStack {
                    Text(env.coordinator.layoutDescription).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { s.update { $0.calibration = ActivationCalibration() } }
                }
            }
            Section("Keyboard shortcut") {
                Toggle("Toggle Nook with a global shortcut", isOn: s.binding(\.hotKey.enabled))
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Button(recording ? "Press keys… (Esc to cancel)" : HotKeyManager.display(s.settings.hotKey)) { startRecording() }
                        .disabled(!s.settings.hotKey.enabled)
                    Button("Default") { s.update { $0.hotKey = .default } }
                }
                Text("Needs ⌘, ⌥ or ⌃. Uses a standard system hot key, so no Accessibility permission is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }  // Esc
            let spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: HotKeyManager.carbonModifiers(from: event.modifierFlags), enabled: true)
            if spec.isValid {
                env.settings.update { $0.hotKey = spec }
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).monospacedDigit().frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: format, value))
    }
}

// MARK: Assistant

struct AssistantSettings: View {
    let env: AppEnvironment
    @State private var endpointDraft = ""
    @State private var endpointError: String?

    var body: some View {
        let s = env.settings
        Form {
            Section("Ollama") {
                HStack {
                    Text("Endpoint")
                    SettingsTextField(prompt: "http://127.0.0.1:11434", text: $endpointDraft, onSubmit: applyEndpoint)
                    Button("Apply", action: applyEndpoint)
                }
                if let endpointError { Text(endpointError).font(.caption).foregroundStyle(.red) }
                Text("Only this Mac is allowed (127.0.0.1, ::1 or localhost). Nook never uses cloud models.").font(.caption).foregroundStyle(.secondary)
                connectionRow
            }
            Section("Model") {
                Picker("Model", selection: Binding(get: { env.assistant.selectedModel }, set: { env.assistant.selectedModel = $0 })) {
                    if !env.assistant.models.contains(where: { $0.name == env.assistant.selectedModel }) {
                        Text("\(env.assistant.selectedModel) (not installed)").tag(env.assistant.selectedModel)
                    }
                    ForEach(env.assistant.models) { m in
                        Text([m.name, m.parameterSize, m.quantization].compactMap { $0 }.joined(separator: " · ")).tag(m.name)
                    }
                }
                Toggle("Let thinking models reason before answering (slower)", isOn: s.binding(\.thinkingEnabled))
                Picker("Keep model in memory", selection: s.binding(\.keepAlive)) {
                    ForEach(ModelKeepAlive.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("While loaded, an 8B model typically uses about 5–6 GB of memory and the GPU is busy only while generating. Nook never loads a model on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits") {
                Stepper("Messages sent as context: \(s.settings.contextMessageLimit)", value: s.binding(\.contextMessageLimit), in: NookSettings.contextMessageRange)
                Stepper("Context window: \(s.settings.contextWindowTokens) tokens", value: s.binding(\.contextWindowTokens), in: NookSettings.contextWindowRange, step: 1024)
                Stepper("Maximum reply length: \(s.settings.maxResponseTokens) tokens", value: s.binding(\.maxResponseTokens), in: NookSettings.maxResponseTokensRange, step: 256)
            }
            Section("History") {
                Picker("Conversation history", selection: s.binding(\.conversationRetention)) {
                    Text("Keep current conversation on this Mac").tag(ConversationRetention.keepCurrent)
                    Text("Memory only (cleared when Nook quits)").tag(ConversationRetention.memoryOnly)
                }
                Button("Clear Conversation History", role: .destructive) { env.assistant.clearHistory() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            endpointDraft = s.settings.ollamaEndpoint
            env.assistant.checkConnection()
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        HStack {
            switch env.assistant.connection {
            case .connected(let version): Label("Connected\(version.isEmpty ? "" : " (Ollama \(version))")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unavailable(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .checking: ProgressView().controlSize(.small); Text("Checking…")
            case .unknown: Text("Not checked")
            }
            Spacer()
            Button("Check") { env.assistant.checkConnection() }
        }
        .font(.callout)
    }

    private func applyEndpoint() {
        do {
            _ = try OllamaEndpoint.validate(endpointDraft)
            env.settings.update { $0.ollamaEndpoint = endpointDraft.trimmingCharacters(in: .whitespaces) }
            endpointError = nil
            env.assistant.checkConnection()
        } catch {
            endpointError = (error as? LocalizedError)?.errorDescription ?? "Invalid endpoint"
        }
    }
}

// MARK: Music

struct MusicSettings: View {
    let env: AppEnvironment

    var body: some View {
        let s = env.settings
        Form {
            // First, so the Client ID field is visible without scrolling.
            CatalogSearchSettings(env: env)
            Section("Spotify") {
                Toggle("Enable music controls", isOn: s.binding(\.musicEnabled))
                LabeledContent("Status", value: env.music.capabilities.explanation)
                HStack {
                    Button("Connect / Check Permission") { env.music.connect() }
                    Button("Open Automation Settings…") { env.music.openAutomationSettings() }
                }
                Text("Nook controls the Spotify app on this Mac through its AppleScript interface (play/pause, skip, seek, volume, current track). It never launches Spotify by itself and doesn't use your Spotify account or the Web API.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Toggle("Load album artwork", isOn: s.binding(\.loadArtwork))
                Text("Artwork is downloaded over HTTPS from Spotify's image CDN (i.scdn.co) when a track changes while the Music view is open. Turn this off to make no network requests for music.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Spin the record while playing", isOn: s.binding(\.vinylAnimation))
            }
            Section("Closed notch") {
                Toggle("Show what's playing on the closed notch", isOn: s.binding(\.nowPlayingPeek))
                Text("While Spotify is playing, the closed notch widens to show the album cover on the left and moving waves on the right. It appears for 2 minutes after the panel closes, when a song starts or when the track changes, and disappears when you pause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refresh") {
                LabeledSlider(title: "Re-sync position every", value: s.binding(\.progressRefreshSeconds), range: NookSettings.refreshRange, format: "%.0f s")
                Text("Track changes arrive as events from Spotify. Position is re-synced only while the Music view is visible and playing, and interpolated in between.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct CatalogSearchSettings: View {
    let env: AppEnvironment
    @State private var clientIDDraft = ""
    @State private var draftError: String?

    var body: some View {
        let catalog = env.catalog
        Section("Spotify Search — Client ID") {
            Text("Search Spotify's full catalogue (songs, artists, albums) from the Music panel. Spotify's app scripting can't search, so this uses Spotify's official Web API with your own developer app. Spotify requires the app owner to have Premium, and allows up to 5 users. No password or client secret is stored; you sign in on Spotify's site in your browser, and the token is kept in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Create an app at developer.spotify.com/dashboard (choose “Web API”; the owner needs Premium).")
                HStack {
                    Text("2. Add this Redirect URI:")
                    Text(catalog.redirectURI).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(catalog.redirectURI, forType: .string)
                    }
                }
                Text("3. Paste the app's Client ID below, then Sign In. Your browser opens Spotify; Nook briefly listens on 127.0.0.1 for the redirect (this exact port).")
                if !catalog.loopbackSignInEnabled {
                    Text("This build can't receive the sign-in redirect yet (the temporary 127.0.0.1 listener is opt-in).")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            HStack {
                Text("Client ID")
                SettingsTextField(prompt: "Paste your 32-character Client ID", text: $clientIDDraft, monospaced: true, onSubmit: apply)
                Button("Save", action: apply)
            }
            if let draftError { Text(draftError).font(.caption).foregroundStyle(.red) }
            HStack {
                switch catalog.authState {
                case .notConfigured: Label("Not set up", systemImage: "circle.dashed")
                case .signedOut: Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                case .signingIn: ProgressView().controlSize(.small); Text("Waiting for Spotify sign-in…")
                case .signedIn: Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .error(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Spacer()
                if catalog.authState == .signedIn && !catalog.playbackScopeGranted {
                    Button("Sign In Again…") { catalog.signIn() }
                        .help("Grants permission to start a chosen song inside its album")
                }
                if catalog.authState == .signedIn {
                    Button("Sign Out") { catalog.signOut() }
                } else {
                    Button("Sign In with Spotify…") { catalog.signIn() }
                        .disabled(catalog.authState == .notConfigured || catalog.authState == .signingIn)
                }
            }
            if catalog.authState == .signedIn {
                Label(catalog.playbackScopeGranted ? "Songs from search play inside their album"
                                                   : "Sign in again to let songs from search play inside their album",
                      systemImage: catalog.playbackScopeGranted ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(catalog.playbackScopeGranted ? Color.secondary : Color.orange)
            }
            Text("When signed in, the text you type in Music › Search is sent to api.spotify.com. One permission is requested: “control playback” (user-modify-playback-state), used only when you press ▶ on a song, to start it inside its album. Without this setup, search can still open Spotify's own search for your text.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { clientIDDraft = env.settings.settings.spotifyClientID }
    }

    private func apply() {
        let candidate = clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || SpotifyAuth.isValidClientID(candidate) {
            env.settings.update { $0.spotifyClientID = candidate }
            draftError = nil
        } else {
            draftError = "A Client ID is 32 letters and digits (0–9, a–f)."
        }
    }
}

// MARK: Shelf

struct ShelfSettings: View {
    let env: AppEnvironment

    var body: some View {
        let s = env.settings
        let shelf = env.shelf
        Form {
            Section("Storage") {
                LabeledContent("Location") {
                    Text(displayPath(shelf.layout?.root))
                        .font(.caption).textSelection(.enabled).lineLimit(3)
                }
                LabeledContent("In use", value: "\(ByteCountFormatter.string(fromByteCount: shelf.storageBytes, countStyle: .file)) · \(shelf.items.count) item(s), \(shelf.recentlyRemoved.count) recently removed")
                HStack {
                    Button("Show in Finder") { shelf.revealStorageFolder() }
                    Button("Clear Shelf…", role: .destructive) { shelf.confirmClearShelf() }.disabled(shelf.items.isEmpty)
                    Button("Empty Recently Removed…", role: .destructive) { shelf.confirmEmptyRecentlyRemoved() }.disabled(shelf.recentlyRemoved.isEmpty)
                }
                Text("Shelf files are not automatically backed up unless your backup tool includes this folder.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Picker("After dragging an item out", selection: s.binding(\.afterDragOut)) {
                    Text("Hide it (recoverable)").tag(AfterDragOutBehavior.hideRecoverably)
                    Text("Keep it on the Shelf").tag(AfterDragOutBehavior.keep)
                }
                Text("An item is hidden only when the destination app reports it accepted the drop. Nook's copy stays on disk under Recently Removed in case the destination reads it later.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Keep recently removed items for \(s.settings.recentlyRemovedRetentionDays) day(s)", value: s.binding(\.recentlyRemovedRetentionDays), in: NookSettings.retentionRange)
                Picker("When the same file is added twice", selection: s.binding(\.duplicatePolicy)) {
                    Text("Skip identical files").tag(DuplicatePolicy.skipIdentical)
                    Text("Always add a new copy").tag(DuplicatePolicy.keepBoth)
                }
            }
            Section("Cleanup (off by default)") {
                Toggle("Suggest cleaning up old or excess items", isOn: s.binding(\.cleanup.enabled))
                Stepper("Older than \(s.settings.cleanup.maxAgeDays ?? 30) day(s)",
                        value: Binding(get: { s.settings.cleanup.maxAgeDays ?? 30 }, set: { v in s.update { $0.cleanup.maxAgeDays = v } }),
                        in: NookSettings.cleanupAgeRange)
                    .disabled(!s.settings.cleanup.enabled)
                Toggle("Limit total storage", isOn: Binding(get: { s.settings.cleanup.maxTotalBytes != nil },
                                                            set: { on in s.update { $0.cleanup.maxTotalBytes = on ? 10 * 1_073_741_824 : nil } }))
                    .disabled(!s.settings.cleanup.enabled)
                if let budget = s.settings.cleanup.maxTotalBytes {
                    Stepper("Budget: \(budget / 1_073_741_824) GB",
                            value: Binding(get: { Int(budget / 1_073_741_824) }, set: { v in s.update { $0.cleanup.maxTotalBytes = Int64(v) * 1_073_741_824 } }),
                            in: 1...500)
                        .disabled(!s.settings.cleanup.enabled)
                }
                Text("Nook never deletes Shelf items on its own. When items match, the Shelf shows a notice and you confirm the list; confirmed items go to Recently Removed first.")
                    .font(.caption).foregroundStyle(.secondary)
                if !shelf.cleanupCandidates.isEmpty {
                    Button("Review \(shelf.cleanupCandidates.count) matching item(s)…") { shelf.reviewCleanup() }
                }
            }
            Section("Recovery") {
                Text(env.diagnostics.lastReconciliation?.summary ?? "Not checked yet").font(.callout)
                Text("On every launch Nook removes unfinished imports (originals are never touched), restores items whose index entry was lost, and flags items whose stored file is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

struct PrivacySettings: View {
    let env: AppEnvironment

    var body: some View {
        Form {
            Section("Local-only operation") {
                Label("No analytics, telemetry, ads or tracking", systemImage: "checkmark.shield")
                Label("No cloud AI: prompts go only to Ollama at \(env.settings.settings.ollamaEndpoint)", systemImage: "checkmark.shield")
                Label("Shelf files are never uploaded", systemImage: "checkmark.shield")
                Label("Nook never reads your clipboard, files or other apps unless you press Paste, drop something, or pick files", systemImage: "checkmark.shield")
            }
            Section("Network requests Nook can make") {
                Text("• http://127.0.0.1:11434 (or your configured loopback endpoint): Ollama, only when the Assistant is open or you send a message.")
                Text("• https://i.scdn.co: album artwork for the current Spotify track and search results, only while the Music view is open (can be turned off).")
                Text("• https://accounts.spotify.com and https://api.spotify.com: only if you set up catalogue search; sign-in, and the text you search for.")
                Text("Nook opens no listening ports, except a 127.0.0.1-only listener while a Spotify sign-in is in progress.")
            }
            .font(.callout)
            Section("What's stored on this Mac") {
                Text("• Shelf items and their metadata: \(displayPath(env.shelf.layout?.root))")
                Text("• Current conversation and saved prompts (Application Support/Nook/Assistant), unless history is set to memory only.")
                Text("• Settings in Nook's preferences.")
            }
            .font(.callout)
            Section("Permissions") {
                Text("• Automation → Spotify: asked only when you click Connect in Music.")
                Text("• No Accessibility, Screen Recording or Full Disk Access is requested.")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}

// MARK: Diagnostics

struct DiagnosticsSettings: View {
    let env: AppEnvironment
    @State private var memory: Int64?
    @State private var cpu: TimeInterval = 0

    var body: some View {
        Form {
            Section("Process") {
                LabeledContent("Memory footprint", value: memory.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—")
                LabeledContent("CPU time since launch", value: String(format: "%.2f s", cpu))
                LabeledContent("Launch to ready", value: env.diagnostics.launchDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
                LabeledContent("Interaction state", value: env.coordinator.stateDescription)
                Button("Refresh") { refresh() }
            }
            Section("Display") {
                Text(env.diagnostics.displaySummary).font(.caption).textSelection(.enabled)
            }
            Section("Features") {
                LabeledContent("Shelf", value: env.shelf.unavailableReason ?? "\(env.shelf.items.count) item(s)")
                LabeledContent("Spotify", value: env.music.capabilities.explanation)
                LabeledContent("Ollama", value: {
                    switch env.assistant.connection {
                    case .connected(let v): return "Connected \(v)"
                    case .unavailable(let m): return m
                    case .checking: return "Checking"
                    case .unknown: return "Not checked (checked only when the Assistant opens)"
                    }
                }())
            }
            Section("Recent events (in memory only, paths redacted)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(env.diagnostics.log.snapshot().reversed()) { entry in
                            Text("\(entry.date.formatted(date: .omitted, time: .standard))  [\(entry.category)] \(entry.message)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        memory = DiagnosticsService.memoryFootprint()
        cpu = DiagnosticsService.cpuTime()
    }
}
