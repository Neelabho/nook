import AppKit
import Carbon
import NookCore
import ServiceManagement
import SwiftUI

/// Wires the feature services together. Each feature is independent: if Ollama or Spotify is
/// unavailable, the Shelf and the rest of the app keep working.
@MainActor
final class AppEnvironment {
    let settings: SettingsService
    let diagnostics: DiagnosticsService
    let shelf: ShelfController
    let music: SpotifyService
    let assistant: AssistantModel
    let catalog: SpotifyCatalogService
    let search: SpotifySearchModel
    let peek: NowPlayingPeekController
    private(set) var coordinator: WindowCoordinator!
    let hotKeys = HotKeyManager()
    let loginItem = LoginItemController()
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(env: self)

    init() {
        settings = SettingsService()
        diagnostics = DiagnosticsService()
        shelf = ShelfController(settings: settings, diagnostics: diagnostics)
        music = SpotifyService(settings: settings, diagnostics: diagnostics)
        assistant = AssistantModel(settings: settings, diagnostics: diagnostics)
        let catalog = SpotifyCatalogService(settings: settings, diagnostics: diagnostics)
        let music = self.music
        self.catalog = catalog
        search = SpotifySearchModel(
            configuration: { catalog.configurationProblem() },
            search: { query in try await catalog.search(query) },
            play: { item in try await AppEnvironment.playFromSearch(item, music: music, catalog: catalog) }
        )
        peek = NowPlayingPeekController(settings: settings, music: music)
        coordinator = WindowCoordinator(settings: settings, shelf: shelf, diagnostics: diagnostics) { [unowned self] in
            AnyView(NookRootContent(model: self.coordinator.model, env: self))
        }
        let peek = self.peek
        peek.onVisibilityChange = { [weak self] visible in self?.coordinator.setPeekVisible(visible) }
        coordinator.onPanelOpened = { peek.panelDidOpen() }
        coordinator.onPanelClosed = { peek.panelDidClose() }
        shelf.interaction = coordinator
        shelf.sendToAssistant = { [weak self] text in
            self?.assistant.receiveText(text)
            self?.coordinator.open(tab: .assistant)
        }
        shelf.dragActivity = { [weak self] active in
            if active { self?.coordinator.shelfDragBegan() } else { self?.coordinator.shelfDragEnded() }
        }
        assistant.saveToShelf = { [weak self] text, title in
            self?.shelf.importText(text, origin: .assistant, title: title)
        }
    }

    /// Plays a search result according to `SearchPlaybackPlan`, without bringing Spotify forward
    /// whenever the Web API can be used.
    static func playFromSearch(_ item: SpotifyCatalogItem, music: SpotifyService, catalog: SpotifyCatalogService) async throws {
        guard let plan = SearchPlaybackPlan.plan(for: item, playbackScopeGranted: catalog.playbackScopeGranted) else {
            throw SpotifyService.PlaybackError(errorDescription: "That isn't a playable Spotify item.")
        }
        catalog.playbackNote = nil
        switch plan {
        case .local(let uri, let reason):
            try await playLocallyKeepingFocus(uri, music: music)
            catalog.playbackNote = "Played via the Spotify app. \(reason)"
            music.recordDiagnostic("search play: local (\(reason))")
        case .webAPI(let context, let offset, let fallback):
            do {
                try await catalog.play(contextURI: context, offsetTrackURI: offset)
                music.recordDiagnostic("search play: Web API ok")
            } catch SpotifyCatalogService.PlaybackFailure.noActiveDevice {
                // Make this Mac the active device without opening Spotify (a plain resume doesn't bring
                // it forward; verified), then retry once.
                music.recordDiagnostic("search play: no active device — resuming locally, then retrying")
                try? await music.resumeLocally()
                try? await Task.sleep(for: .milliseconds(900))
                do {
                    try await catalog.play(contextURI: context, offsetTrackURI: offset)
                    music.recordDiagnostic("search play: Web API ok after activating this Mac")
                } catch {
                    try await fallBack(fallback, error: error, music: music, catalog: catalog)
                }
            } catch {
                try await fallBack(fallback, error: error, music: music, catalog: catalog)
            }
            try? await Task.sleep(for: .milliseconds(400))
            await music.refresh()
        }
    }

    private static func fallBack(_ uri: String, error: Error, music: SpotifyService, catalog: SpotifyCatalogService) async throws {
        let why = (error as? LocalizedError)?.errorDescription ?? "the Web API didn't respond"
        music.recordDiagnostic("search play: Web API failed — \(why); falling back to the Spotify app")
        try await playLocallyKeepingFocus(uri, music: music)
        catalog.playbackNote = "Played via the Spotify app (\(why)). A song played this way doesn't continue through its album."
    }

    /// AppleScript `play track` brings Spotify to the front; give focus back to whatever was frontmost.
    private static func playLocallyKeepingFocus(_ uri: String, music: SpotifyService) async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        try await music.playTrack(uri: uri)
        if let previous, previous.bundleIdentifier != SpotifyService.bundleID,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SpotifyService.bundleID {
            previous.activate()
        }
    }

    func start() {
        let started = Date()
        coordinator.start()
        statusItem = StatusItemController(env: self)
        statusItem?.setVisible(settings.settings.showMenuBarIcon)
        registerHotKey()
        music.start()
        peek.start()
        settings.onChange { [weak self] old, new in self?.settingsChanged(old: old, new: new) }
        loginItem.enableOnFirstLaunch()
        Task {
            await shelf.open()
            diagnostics.launchDuration = Date().timeIntervalSince(started)
        }
    }

    func shutdown() {
        hotKeys.unregister()
        music.stop()
        assistant.stop()
        coordinator.stop()
    }

    private func registerHotKey() {
        let spec = settings.settings.hotKey
        guard spec.enabled else { hotKeys.unregister(); return }
        if !hotKeys.register(spec, handler: { [weak self] in self?.coordinator.toggle() }) {
            diagnostics.record("hotkey", "Shortcut \(spec.modifierSymbols)\(spec.keyCode) is unavailable (in use by another app?)")
        }
    }

    private func settingsChanged(old: NookSettings, new: NookSettings) {
        if old.hotKey != new.hotKey { registerHotKey() }
        if old.showMenuBarIcon != new.showMenuBarIcon { statusItem?.setVisible(new.showMenuBarIcon) }
        if old.musicEnabled != new.musicEnabled { new.musicEnabled ? music.start() : music.stop() }
        if old.cleanup != new.cleanup { shelf.evaluateCleanupPolicy() }
        if old.nowPlayingPeek != new.nowPlayingPeek || old.musicEnabled != new.musicEnabled { peek.settingsChanged() }
        if old.spotifyClientID != new.spotifyClientID {
            catalog.forgetToken(for: old.spotifyClientID)   // tokens belong to the previous Client ID
            catalog.reloadState()
        }
        if old.conversationRetention != new.conversationRetention, new.conversationRetention == .memoryOnly {
            assistant.clearHistoryFile()
        }
    }

    /// Diagnostics probe: on SIGUSR1, writes live state and a render of the panel into this app's
    /// own temporary folder. Nothing leaves the container; nothing runs unless signalled.
    func writeDiagnosticsSnapshot() {
        let dir = FileManager.default.temporaryDirectory
        var state = coordinator.debugState()
        state.merge(peek.debugState) { $1 }
        state["shelfVisible"] = shelf.items.map { ["name": $0.displayName, "kind": $0.kind.rawValue, "type": $0.contentType, "status": $0.status.rawValue, "bytes": $0.byteSize ?? -1] }
        state["shelfRecentlyRemoved"] = shelf.recentlyRemoved.count
        state["shelfImportsInFlight"] = shelf.importsInFlight
        state["shelfBanner"] = shelf.banner?.text ?? ""
        state["shelfSelection"] = shelf.selection.count
        state["musicStatus"] = "\(music.capabilities.status)"
        state["musicTrack"] = music.snapshot.map { "\($0.state.rawValue): \($0.track?.title ?? "-") — \($0.track?.artist ?? "-") @\(Int($0.positionSeconds ?? -1))s vol \($0.volume ?? -1)" } ?? "none"
        state["musicArtworkLoaded"] = music.artwork != nil
        state["musicError"] = music.lastError ?? ""
        state["catalogAuth"] = "\(catalog.authState)"
        state["catalogPlaybackScope"] = catalog.playbackScopeGranted
        state["catalogClientIDConfigured"] = !settings.settings.spotifyClientID.isEmpty
        state["catalogLoopbackEnabled"] = catalog.loopbackSignInEnabled
        state["catalogRedirectURI"] = catalog.redirectURI
        loginItem.refresh()
        state["loginItemStatus"] = switch loginItem.status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
        state["loginItemError"] = loginItem.lastError ?? ""
        state["bundlePath"] = Bundle.main.bundlePath
        state["assistantConnection"] = "\(assistant.connection)"
        state["assistantMessages"] = assistant.conversation.messages.count
        state["assistantGenerating"] = assistant.isGenerating
        state["assistantError"] = assistant.error ?? ""
        state["memoryBytes"] = DiagnosticsService.memoryFootprint() ?? -1
        state["cpuSeconds"] = DiagnosticsService.cpuTime()
        state["log"] = diagnostics.log.snapshot().suffix(60).map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.message)" }
        if let json = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: dir.appendingPathComponent("nook-state.json"), options: .atomic)
        }
        if let png = coordinator.renderPanelPNG() {
            try? png.write(to: dir.appendingPathComponent("nook-panel.png"), options: .atomic)
        }
    }

    /// Lets features do work only while they're on screen.
    func featureVisibilityChanged() {
        let model = coordinator.model
        music.setVisible(model.isOpen && model.selectedTab == .music)
        if !(model.isOpen && model.selectedTab == .music) { search.cancel() }
        if model.isOpen && model.selectedTab == .assistant { assistant.panelDidAppear() }
        if model.isOpen && model.selectedTab == .shelf { shelf.evaluateCleanupPolicy() }
    }

    func openSettings(tab: SettingsTab = .general) {
        coordinator.close()
        settingsWindow.show(tab: tab)
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NookMainMenu.install()      // makes ⌘A/⌘C/⌘V/⌘X/⌘Z work in text fields
        if SelfTest.requested {
            Task {
                var status = await SelfTest.run()
                if CommandLine.arguments.contains("--assistant") { status |= await SelfTest.runAssistant() }
                if CommandLine.arguments.contains("--spotify") { status |= await SelfTest.runSpotify() }
                if CommandLine.arguments.contains("--loopback") { status |= await SelfTest.runLoopback() }
                if CommandLine.arguments.contains("--catalog") { status |= await SelfTest.runCatalog() }
                if CommandLine.arguments.contains("--catalog-play") { status |= await SelfTest.runCatalogPlayback() }
                if CommandLine.arguments.contains("--activation-probe") { status |= await SelfTest.runActivationProbe() }
                if let i = CommandLine.arguments.firstIndex(of: "--restore-track"), CommandLine.arguments.count > i + 3 {
                    status |= await SelfTest.restoreTrack(uri: CommandLine.arguments[i + 1], album: CommandLine.arguments[i + 2],
                                                          seconds: Double(CommandLine.arguments[i + 3]) ?? 0)
                }
                exit(status)
            }
            return
        }
        // Single instance: if another copy is already running, hand over to it.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current && $0.activationPolicy != .prohibited }
        if !others.isEmpty, Bundle.main.bundleIdentifier != nil {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }
        let env = AppEnvironment()
        self.env = env
        env.start()
        installTerminationSignalHandler()
    }

    private var signalSource: DispatchSourceSignal?

    /// Treat SIGTERM (e.g. from the install/uninstall scripts) like Quit, so shutdown is orderly.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        signal(SIGUSR1, SIG_IGN)
        let probe = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        probe.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.env?.writeDiagnosticsSnapshot() }
        }
        probe.resume()
        probeSource = probe

        // Diagnostics: SIGUSR2 toggles the panel open on the Music tab (for measuring the visible dock).
        signal(SIGUSR2, SIG_IGN)
        let toggle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        toggle.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let coordinator = self?.env?.coordinator else { return }
                // Never takes keyboard focus: an earlier version captured typing meant for the frontmost app.
                if coordinator.model.isOpen { coordinator.close() } else { coordinator.open(tab: .music, takeKeyboardFocus: false) }
            }
        }
        toggle.resume()
        toggleSource = toggle
    }

    private var probeSource: DispatchSourceSignal?
    private var toggleSource: DispatchSourceSignal?

    /// Re-opening Nook.app (Finder/Spotlight) while it runs shows Settings: a way back in even with
    /// the menu bar icon hidden and hover disabled.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        env?.openSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let shelf = env?.shelf, shelf.importsInFlight > 0 {
            let alert = NSAlert()
            alert.messageText = "Nook is still adding \(shelf.importsInFlight) item(s) to the Shelf."
            alert.informativeText = "If you quit now, unfinished copies are discarded on next launch. Your originals are never affected."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        env?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Global shortcut (Carbon hot keys: no Accessibility permission required)

@MainActor
final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (() -> Void)?
    private static var current: HotKeyManager?

    @discardableResult
    func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler
        Self.current = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.current?.handler?() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x4E4F4F4B), id: 1)   // 'NOOK'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        ref = nil
        handlerRef = nil
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
            15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space", 36: "↩", 48: "⇥",
            50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[code] ?? "Key \(code)"
    }

    static func display(_ spec: HotKeySpec) -> String { spec.modifierSymbols + keyName(spec.keyCode) }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= HotKeySpec.command }
        if flags.contains(.shift) { m |= HotKeySpec.shift }
        if flags.contains(.option) { m |= HotKeySpec.option }
        if flags.contains(.control) { m |= HotKeySpec.control }
        return m
    }
}

// MARK: - Launch at login (ServiceManagement, no LaunchAgents)

@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?
    private static let offeredKey = "loginItem.firstLaunchHandled"

    func refresh() { status = SMAppService.mainApp.status }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// The product brief asks for launch at login, so it's registered once on first launch.
    /// The user can turn it off in Settings; it is never re-enabled after that.
    func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.offeredKey) else { refresh(); return }
        // Only register an installed copy (in /Applications or ~/Applications), never a build folder
        // or `swift run`, so a test build can't hijack the login item.
        guard Self.isInstalledLocation(Bundle.main.bundleURL),
              Bundle.main.bundleIdentifier?.hasSuffix(".staging") != true else { refresh(); return }
        UserDefaults.standard.set(true, forKey: Self.offeredKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    static func isInstalledLocation(_ url: URL) -> Bool {
        InstallLocation.isInstalled(url)
    }

    var statusText: String {
        switch status {
        case .enabled: return "Nook opens automatically when you log in."
        case .requiresApproval: return "Waiting for your approval in System Settings › General › Login Items."
        case .notRegistered: return "Nook won't open at login."
        case .notFound: return "Login item unavailable (run Nook from its installed .app bundle)."
        @unknown default: return "Unknown login item status."
        }
    }
}

// MARK: - Menu bar fallback

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private unowned let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Nook")
            item.button?.toolTip = "Nook"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = env.settings.settings
        let shortcut = s.hotKey.enabled ? " (\(HotKeyManager.display(s.hotKey)))" : ""
        menu.addItem(ClosureMenuItem("Show Nook\(shortcut)", symbol: "rectangle.topthird.inset.filled") { [env] in env.coordinator.open(tab: nil) })
        menu.addItem(ClosureMenuItem("Shelf", symbol: "tray.full") { [env] in env.coordinator.open(tab: .shelf) })
        menu.addItem(ClosureMenuItem("Assistant", symbol: "sparkles") { [env] in env.coordinator.open(tab: .assistant) })
        menu.addItem(ClosureMenuItem("Music", symbol: "music.note") { [env] in env.coordinator.open(tab: .music) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Files to Shelf…", symbol: "plus") { [env] in env.shelf.presentAddFilesPanel() })
        menu.addItem(ClosureMenuItem("Paste to Shelf", symbol: "doc.on.clipboard") { [env] in env.shelf.paste() })
        menu.addItem(.separator())
        let hover = ClosureMenuItem(s.hoverEnabled ? "Pause Notch Hover" : "Resume Notch Hover", symbol: s.hoverEnabled ? "pause.circle" : "play.circle") { [env] in
            env.settings.update { $0.hoverEnabled.toggle() }
        }
        menu.addItem(hover)
        menu.addItem(ClosureMenuItem("Settings…", symbol: "gearshape", key: ",") { [env] in env.openSettings() })
        menu.addItem(ClosureMenuItem("Diagnostics…", symbol: "stethoscope") { [env] in env.openSettings(tab: .diagnostics) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Nook", key: "q") { NSApp.terminate(nil) })
    }
}
