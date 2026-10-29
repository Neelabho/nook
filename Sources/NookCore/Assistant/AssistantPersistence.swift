import Foundation

/// The single active conversation, persisted locally when retention allows.
public struct Conversation: Codable, Equatable, Sendable {
    public var id: UUID
    public var model: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(id: UUID = UUID(), model: String? = nil, messages: [ChatMessage] = [], updatedAt: Date = Date()) {
        self.id = id
        self.model = model
        self.messages = messages
        self.updatedAt = updatedAt
    }

    /// Messages sent to the model: an optional system prompt plus the most recent turns,
    /// bounded so context (and memory) stays predictable.
    public func contextWindow(limit: Int, systemPrompt: String?) -> [ChatMessage] {
        var recent = Array(messages.filter { $0.role != .system }.suffix(max(1, limit)))
        // Never start the context with an assistant turn.
        while recent.first?.role == .assistant { recent.removeFirst() }
        if let systemPrompt, !systemPrompt.isEmpty {
            return [ChatMessage(role: .system, content: systemPrompt)] + recent
        }
        return recent
    }
}

public struct SavedPrompt: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, body: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

/// Small JSON file store for assistant data under Application Support. Writes are atomic.
public struct AssistantStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory(productName: String = "Nook") throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent(productName, isDirectory: true).appendingPathComponent("Assistant", isDirectory: true)
    }

    private var conversationURL: URL { directory.appendingPathComponent("conversation.json") }
    private var promptsURL: URL { directory.appendingPathComponent("prompts.json") }

    public func loadConversation() -> Conversation? {
        guard let data = try? Data(contentsOf: conversationURL) else { return nil }
        return try? JSONCoding.decoder().decode(Conversation.self, from: data)
    }

    public func saveConversation(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(conversation).write(to: conversationURL, options: [.atomic])
    }

    public func deleteConversation() {
        try? FileManager.default.removeItem(at: conversationURL)
    }

    public func loadPrompts() -> [SavedPrompt] {
        guard let data = try? Data(contentsOf: promptsURL) else { return [] }
        return (try? JSONCoding.decoder().decode([SavedPrompt].self, from: data)) ?? []
    }

    public func savePrompts(_ prompts: [SavedPrompt]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(prompts).write(to: promptsURL, options: [.atomic])
    }
}

/// The practical quick actions offered in the assistant.
public enum AssistantAction: String, CaseIterable, Sendable, Identifiable {
    case ask, explain, rewrite, shorten, friendlier, formal, summarize, codeReview, explainError, formatCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return "Ask"
        case .explain: return "Explain"
        case .rewrite: return "Improve"
        case .shorten: return "Shorten"
        case .friendlier: return "Friendlier"
        case .formal: return "More formal"
        case .summarize: return "Summarize"
        case .codeReview: return "Review code"
        case .explainError: return "Explain error"
        case .formatCode: return "Format code"
        }
    }

    public var symbol: String {
        switch self {
        case .ask: return "bubble.left"
        case .explain: return "lightbulb"
        case .rewrite: return "wand.and.stars"
        case .shorten: return "arrow.down.right.and.arrow.up.left"
        case .friendlier: return "face.smiling"
        case .formal: return "briefcase"
        case .summarize: return "text.redaction"
        case .codeReview: return "checklist"
        case .explainError: return "exclamationmark.triangle"
        case .formatCode: return "curlybraces"
        }
    }

    /// Wraps user-provided text in a task instruction. The text is clearly delimited so it is
    /// treated as material to work on rather than as instructions.
    public func prompt(for input: String) -> String {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func wrap(_ instruction: String) -> String {
            "\(instruction)\n\n<text>\n\(body)\n</text>"
        }
        switch self {
        case .ask: return body
        case .explain: return wrap("Explain the following text clearly and concisely. Define any jargon.")
        case .rewrite: return wrap("Rewrite the following text to be clearer and better written while keeping its meaning and tone. Reply with only the rewritten text.")
        case .shorten: return wrap("Shorten the following text substantially while keeping the key points. Reply with only the shortened text.")
        case .friendlier: return wrap("Rewrite the following text in a warmer, friendlier tone. Reply with only the rewritten text.")
        case .formal: return wrap("Rewrite the following text in a professional, formal tone. Reply with only the rewritten text.")
        case .summarize: return wrap("Summarize the following text as a few short bullet points, then one sentence with the main takeaway.")
        case .codeReview: return wrap("Review this code. Point out bugs, risky edge cases and clear improvements, most important first. Keep it brief and show corrected code where useful.")
        case .explainError: return wrap("Explain what this error means, its most likely causes, and how to fix it.")
        case .formatCode: return wrap("Reformat this code with idiomatic style for its language. Do not change behaviour. Reply with a single code block.")
        }
    }

    public static let systemPrompt = """
    You are Nook, a concise assistant running locally on the user's Mac. Answer directly. \
    Use Markdown for lists and fenced code blocks with a language tag. You cannot access the user's files, \
    apps, browser or the internet; work only with what the user provides.
    """
}
