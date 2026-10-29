import NookCore
import SwiftUI

struct AssistantView: View {
    @Bindable var assistant: AssistantModel
    @Bindable var notch: NotchModel
    var onLarge: (Bool) -> Void

    @FocusState private var inputFocused: Bool
    @State private var showingPrompts = false
    @State private var newPromptTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            connectionNotice
            transcript
            composer
        }
        .onAppear { assistant.panelDidAppear() }
        // Focus must be assigned after the view is installed in the (key) panel; doing it in
        // onAppear was observed to have no effect, leaving keyboard users unable to type.
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Assistant").font(.system(size: 15, weight: .semibold))
            modelMenu
            Spacer()
            if let loaded = assistant.loadedModel, let bytes = loaded.sizeBytes {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip").font(.system(size: 10))
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) in memory")
                }
                .font(.system(size: 11))
                .foregroundStyle(Nook.Palette.tertiaryText)
                .help("Ollama is holding the model in memory. It unloads automatically after the keep-alive period, or now with Unload.")
                Button("Unload") { assistant.unloadModel() }.buttonStyle(PillButtonStyle())
                    .help("Free the model's memory now")
            }
            GlassIconButton(systemImage: "text.book.closed", label: "Prompt scratchpad", isActive: showingPrompts, size: 24) {
                showingPrompts.toggle()
            }
            .popover(isPresented: $showingPrompts, arrowEdge: .bottom) { promptLibrary }
            GlassIconButton(systemImage: "square.and.pencil", label: "New conversation", size: 24) { assistant.newConversation() }
        }
    }

    private var modelMenu: some View {
        Menu {
            if assistant.models.isEmpty {
                Text("No local models found")
            }
            ForEach(assistant.models) { model in
                Button {
                    assistant.selectedModel = model.name
                } label: {
                    if model.name == assistant.selectedModel { Image(systemName: "checkmark") }
                    Text([model.name, model.parameterSize].compactMap { $0 }.joined(separator: " · "))
                }
            }
            Divider()
            Button("Refresh Models") { assistant.checkConnection() }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(connectionColor).frame(width: 6, height: 6)
                Text(assistant.selectedModel).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(Nook.Palette.primaryText)
            .darkGlass(in: Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model (local Ollama only)")
        .accessibilityLabel("Model: \(assistant.selectedModel)")
    }

    private var connectionColor: Color {
        switch assistant.connection {
        case .connected: return assistant.selectedModelInstalled ? Nook.Palette.success : Nook.Palette.warning
        case .unavailable: return Nook.Palette.danger
        case .checking, .unknown: return Nook.Palette.tertiaryText
        }
    }

    @ViewBuilder
    private var connectionNotice: some View {
        switch assistant.connection {
        case .unavailable(let message):
            HStack(spacing: 8) {
                StatusBadge(text: message, tone: .danger)
                Spacer()
                Button("Open Ollama") { assistant.openOllamaApp() }.buttonStyle(PillButtonStyle())
                Button("Retry") { assistant.checkConnection() }.buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Retry (⌘R)")
            }
        case .connected where !assistant.selectedModelInstalled && !assistant.models.isEmpty:
            StatusBadge(text: "“\(assistant.selectedModel)” isn't installed. Pick a local model above. Nook never downloads models.", tone: .warning)
        case .connected where assistant.models.isEmpty:
            StatusBadge(text: "Ollama is running but has no local models. Install one yourself, e.g. `ollama pull qwen3:8b`.", tone: .warning)
        case .checking:
            StatusBadge(text: "Checking Ollama…", tone: .working)
        default:
            EmptyView()
        }
        if let error = assistant.error {
            HStack {
                StatusBadge(text: error, tone: .danger)
                Spacer()
                Button("Dismiss") { assistant.dismissError() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if assistant.conversation.messages.isEmpty && !assistant.isGenerating {
                        emptyHints
                    }
                    ForEach(assistant.conversation.messages) { message in
                        MessageRow(message: message, assistant: assistant)
                            .id(message.id)
                    }
                    if assistant.isGenerating {
                        StreamingRow(text: assistant.streamingText, thinking: assistant.streamingThinking)
                            .id("streaming")
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .onChange(of: assistant.streamingText) { proxy.scrollTo("streaming", anchor: .bottom) }
            .onChange(of: assistant.conversation.messages.count) {
                if let last = assistant.conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything, or paste text and pick an action.").font(.system(size: 12)).foregroundStyle(Nook.Palette.secondaryText)
            Text("Runs entirely on this Mac through Ollama. Nothing is sent to the cloud, and Nook can't see your files or apps.")
                .font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
        }
        .padding(.top, 4)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(AssistantAction.allCases) { action in
                        Button {
                            assistant.action = action
                            inputFocused = true
                        } label: {
                            Label(action.title, systemImage: action.symbol).labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(PillButtonStyle(prominent: assistant.action == action))
                        .help(action == .ask ? "Ask a question" : "\(action.title) the text you paste below")
                    }
                }
            }
            .scrollIndicators(.never)

            HStack(alignment: .bottom, spacing: 6) {
                TextField(placeholder, text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...(notch.isLarge ? 10 : 3))
                    .focused($inputFocused)
                    .onSubmit { assistant.send() }
                    .foregroundStyle(Nook.Palette.primaryText)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassField(focused: inputFocused)
                    .accessibilityLabel("Message to assistant")
                GlassIconButton(systemImage: "doc.on.clipboard", label: "Paste clipboard text", size: 28) { assistant.pasteClipboard() }
                GlassIconButton(systemImage: "tray.and.arrow.down", label: "Save draft to Shelf as a note", size: 28) { assistant.captureDraftToShelf() }
                if assistant.isGenerating {
                    GlassIconButton(systemImage: "stop.fill", label: "Stop generating", isActive: true, size: 28) { assistant.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    GlassIconButton(systemImage: "arrow.up", label: "Send (Return)", isActive: true, size: 28) { assistant.send() }
                        .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var placeholder: String {
        switch assistant.action {
        case .ask: return "Ask \(assistant.selectedModel)…"
        default: return "Paste the text to \(assistant.action.title.lowercased())…"
        }
    }

    private var promptLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt scratchpad").font(.headline)
            Text("Saved locally. Click a prompt to load it into the composer.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Title", text: $newPromptTitle).textFieldStyle(.roundedBorder)
                Button("Save Current Draft") {
                    assistant.savePrompt(title: newPromptTitle, body: assistant.draft)
                    newPromptTitle = ""
                }
                .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            if assistant.prompts.isEmpty {
                Text("No saved prompts yet.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(assistant.prompts) { prompt in
                        HStack {
                            Button {
                                assistant.usePrompt(prompt)
                                showingPrompts = false
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(prompt.title).font(.system(size: 12, weight: .medium))
                                    Text(prompt.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) { assistant.deletePrompt(prompt) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete prompt")
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider()
            Button("Clear Conversation History…", role: .destructive) { assistant.clearHistory() }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let assistant: AssistantModel
    @State private var hovering = false
    @State private var showThinking = false
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.system(size: 12.5))
                    .lineLimit(12)
                    .foregroundStyle(Nook.Palette.primaryText)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .darkGlass(in: RoundedRectangle(cornerRadius: Nook.Glass.fieldRadius, style: .continuous), tint: Nook.Palette.accent.opacity(0.24))
                    .contextMenu {
                        Button("Copy") { assistant.copy(message.content) }
                    }
            }
            .accessibilityLabel("You: \(message.content)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let thinking = message.thinking, !thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(thinking).font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
                    } label: {
                        Text("Reasoning").font(.system(size: 11)).foregroundStyle(Nook.Palette.tertiaryText)
                    }
                }
                MarkdownView(text: message.content, copy: { assistant.copy($0) })
                // Always present (faint at rest) so the buttons can't vanish as the pointer moves onto
                // them: hovering the glass buttons made the row's hover flip to false (reported).
                HStack(spacing: 6) {
                    Button { copyReply() } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("Copy this reply")
                    Button { assistant.saveReplyToShelf(message) } label: { Label("To Shelf", systemImage: "tray.and.arrow.down") }
                        .buttonStyle(PillButtonStyle())
                        .help("Save this reply to the Shelf as a note")
                    if let tps = message.stats?.tokensPerSecond {
                        Text(String(format: "%.0f tok/s", tps)).font(.system(size: 10)).foregroundStyle(Nook.Palette.tertiaryText)
                    }
                }
                .opacity(hovering || copied ? 1 : 0.5)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .contentShape(Rectangle())
            .onHover { inside in if inside { hovering = true } else { hovering = false } }
            .contextMenu {
                Button("Copy Reply") { copyReply() }
                let blocks = MarkdownParser.codeBlocks(in: message.content)
                if !blocks.isEmpty {
                    Button(blocks.count == 1 ? "Copy Code" : "Copy First Code Block") { assistant.copy(blocks[0]) }
                }
                Button("Save Reply to Shelf") { assistant.saveReplyToShelf(message) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Copy reply") { copyReply() }
        }
    }

    private func copyReply() {
        assistant.copy(message.content)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

struct StreamingRow: View {
    let text: String
    let thinking: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                StatusBadge(text: thinking.isEmpty ? "Generating… (the first reply may take a few seconds while the model loads)" : "Thinking…", tone: .working)
            } else {
                MarkdownView(text: text, copy: nil)
            }
        }
        .accessibilityLabel(text.isEmpty ? "Generating" : text)
    }
}
