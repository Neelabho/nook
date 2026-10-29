import AppKit
import NookCore
import Observation

/// Local assistant backed by Ollama. Lazy by design: nothing touches Ollama until the assistant
/// is shown or a message is sent. There is no background polling, no preloading, and no cloud fallback.
@MainActor
@Observable
final class AssistantModel {
    enum Connection: Equatable {
        case unknown
        case checking
        case connected(version: String)
        case unavailable(String)
    }

    private(set) var connection: Connection = .unknown
    private(set) var models: [OllamaModel] = []
    private(set) var conversation = Conversation()
    private(set) var isGenerating = false
    private(set) var streamingText = ""
    private(set) var streamingThinking = ""
    private(set) var error: String?
    private(set) var loadedModel: OllamaRunningModel?
    private(set) var prompts: [SavedPrompt] = []
    var draft = ""
    var action: AssistantAction = .ask

    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private let diagnostics: DiagnosticsService
    @ObservationIgnored private var store: AssistantStore?
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var thinkingCapable: [String: Bool] = [:]
    @ObservationIgnored var saveToShelf: ((String, String?) -> Void)?

    init(settings: SettingsService, diagnostics: DiagnosticsService, storeDirectory: URL? = nil) {
        self.settings = settings
        self.diagnostics = diagnostics
        store = (storeDirectory ?? (try? AssistantStore.defaultDirectory())).map(AssistantStore.init(directory:))
        if settings.settings.conversationRetention == .keepCurrent, let saved = store?.loadConversation() {
            conversation = saved
        }
        prompts = store?.loadPrompts() ?? []
    }

    var selectedModel: String {
        get { settings.settings.preferredModel }
        set { settings.update { $0.preferredModel = newValue } }
    }

    var selectedModelInstalled: Bool { models.contains { $0.name == selectedModel } }

    private func client() throws -> OllamaClient {
        try OllamaClient(endpoint: settings.settings.ollamaEndpoint)
    }

    // MARK: Connectivity (on demand only)

    /// Called when the assistant becomes visible. Throttled so reopening the panel repeatedly
    /// doesn't generate requests.
    func panelDidAppear() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 30, case .connected = connection { return }
        checkConnection()
    }

    func checkConnection() {
        lastCheck = Date()
        connection = .checking
        Task {
            do {
                let client = try client()
                let version = try await client.version()
                let list = try await client.listModels()
                models = list
                connection = .connected(version: version)
                if !list.contains(where: { $0.name == selectedModel }), let qwen = list.first(where: { $0.name.hasPrefix("qwen3:8b") }) {
                    selectedModel = qwen.name
                }
                loadedModel = try? await client.runningModels().first { $0.name == selectedModel }
            } catch {
                connection = .unavailable(Self.describe(error))
                models = []
                return
            }
            self.error = nil
        }
    }

    func openOllamaApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") else {
            error = "The Ollama app wasn't found. Start Ollama with `ollama serve` in Terminal."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.checkConnection()
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Generation

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        let prompt = action.prompt(for: text)
        let sentDraft = draft
        let sentAction = action
        draft = ""
        action = .ask
        submit(prompt, restoreOnFailure: (sentDraft, sentAction))
    }

    func submit(_ prompt: String, restoreOnFailure: (String, AssistantAction)? = nil) {
        guard !isGenerating else { return }
        error = nil
        conversation.messages.append(ChatMessage(role: .user, content: prompt))
        conversation.model = selectedModel
        conversation.updatedAt = Date()
        persist()

        let model = selectedModel
        let s = settings.settings
        let context = conversation.contextWindow(limit: s.contextMessageLimit, systemPrompt: AssistantAction.systemPrompt)
        isGenerating = true
        streamingText = ""
        streamingThinking = ""

        generation = Task { [weak self] in
            guard let self else { return }
            var stats: GenerationStats?
            var pendingText = ""
            var pendingThinking = ""
            var lastFlush = ContinuousClock.now
            do {
                let client = try self.client()
                let think = await self.supportsThinking(model, client: client) ? s.thinkingEnabled : nil
                let options = ChatOptions(contextWindow: s.contextWindowTokens, maxTokens: s.maxResponseTokens, think: think, keepAlive: s.keepAlive.rawValue)
                if case .connected = self.connection {} else { self.connection = .checking }
                for try await event in client.chat(model: model, messages: context, options: options) {
                    if case .checking = self.connection { self.connection = .connected(version: "") }
                    switch event {
                    case .content(let t): pendingText += t
                    case .thinking(let t): pendingThinking += t
                    case .done(let st): stats = st
                    }
                    // Batch UI updates (~20/s) instead of re-rendering for every token.
                    if ContinuousClock.now - lastFlush > .milliseconds(50) {
                        self.streamingText += pendingText
                        self.streamingThinking += pendingThinking
                        pendingText = ""
                        pendingThinking = ""
                        lastFlush = .now
                    }
                }
                self.streamingText += pendingText
                self.streamingThinking += pendingThinking
                // Cancelling the consuming task ends the stream without throwing; a missing `done`
                // event means the reply was cut short.
                self.finish(stats: stats, cancelled: Task.isCancelled || stats == nil)
            } catch {
                self.streamingText += pendingText
                self.streamingThinking += pendingThinking
                let ollamaError = error as? OllamaError
                if ollamaError == .cancelled || error is CancellationError {
                    self.finish(stats: nil, cancelled: true)
                } else if self.streamingText.isEmpty, let (text, action) = restoreOnFailure {
                    // Nothing was generated: take the message back out of the transcript and return
                    // it to the composer so it can be re-sent after fixing the problem.
                    if self.conversation.messages.last?.role == .user { self.conversation.messages.removeLast() }
                    self.finish(stats: nil, cancelled: true)
                    if self.draft.isEmpty { self.draft = text; self.action = action }
                    self.report(error)
                } else {
                    self.finish(stats: nil, cancelled: true)
                    self.report(error)
                }
            }
        }
    }

    private func supportsThinking(_ model: String, client: OllamaClient) async -> Bool {
        if let known = thinkingCapable[model] { return known }
        let caps = (try? await client.capabilities(of: model)) ?? []
        let result = caps.contains("thinking")
        thinkingCapable[model] = result
        return result
    }

    private func finish(stats: GenerationStats?, cancelled: Bool) {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            var message = ChatMessage(role: .assistant, content: cancelled ? text + "\n\n*(stopped)*" : text,
                                      thinking: streamingThinking.isEmpty ? nil : streamingThinking, stats: stats)
            message.createdAt = Date()
            conversation.messages.append(message)
        }
        streamingText = ""
        streamingThinking = ""
        isGenerating = false
        generation = nil
        conversation.updatedAt = Date()
        persist()
        if let stats, let tps = stats.tokensPerSecond {
            diagnostics.record("assistant", String(format: "Reply: %d tokens at %.1f tok/s (load %.2fs)", stats.evalCount ?? 0, tps,
                                                   Double(stats.loadDurationNanos ?? 0) / 1e9))
        }
        refreshLoadedModel()
    }

    func stop() {
        generation?.cancel()
    }

    func dismissError() { error = nil }

    /// Connection problems are shown once, in the connection notice; other errors in the error line.
    private func report(_ error: Error) {
        let message = Self.describe(error)
        if (error as? OllamaError) == .serviceUnavailable {
            connection = .unavailable(message)
            self.error = nil
        } else {
            self.error = message
        }
    }

    private func refreshLoadedModel() {
        let model = selectedModel
        Task {
            loadedModel = try? await client().runningModels().first { $0.name == model }
        }
    }

    func unloadModel() {
        let model = selectedModel
        Task {
            do {
                try await client().unload(model: model)
                loadedModel = nil
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    // MARK: Conversation management

    func newConversation() {
        stop()
        conversation = Conversation(model: selectedModel)
        error = nil
        persist()
    }

    func clearHistoryFile() { store?.deleteConversation() }

    func clearHistory() {
        stop()
        conversation = Conversation(model: selectedModel)
        store?.deleteConversation()
    }

    private func persist() {
        guard settings.settings.conversationRetention == .keepCurrent else {
            store?.deleteConversation()
            return
        }
        try? store?.saveConversation(conversation)
    }

    /// Explicit user action only.
    func pasteClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            draft += (draft.isEmpty ? "" : "\n") + text
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func receiveText(_ text: String) {
        draft = text
        action = .explain
    }

    // MARK: Quick capture & prompts

    func captureDraftToShelf() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        saveToShelf?(text, nil)
        draft = ""
    }

    func saveReplyToShelf(_ message: ChatMessage) {
        saveToShelf?(message.content, "Assistant reply")
    }

    func savePrompt(title: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompts.insert(SavedPrompt(title: name.isEmpty ? String(trimmed.prefix(40)) : name, body: trimmed), at: 0)
        try? store?.savePrompts(prompts)
    }

    func deletePrompt(_ prompt: SavedPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        try? store?.savePrompts(prompts)
    }

    func usePrompt(_ prompt: SavedPrompt) {
        draft = prompt.body
    }
}
