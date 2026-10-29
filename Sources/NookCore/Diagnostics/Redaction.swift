import Foundation

/// Keeps file names, paths and user content out of logs.
public enum Redactor {
    /// "/Users/me/Documents/Taxes 2025.pdf" -> "<file .pdf>"
    public static func file(_ url: URL?) -> String {
        guard let url else { return "<none>" }
        let ext = url.pathExtension
        return ext.isEmpty ? "<file>" : "<file .\(ext.prefix(8))>"
    }

    /// Replaces anything that looks like an absolute path inside free text.
    public static func text(_ message: String) -> String {
        let pattern = #"(/(?:Users|Volumes|private|var|tmp)/[^\s"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, range: range, withTemplate: "<path>")
    }
}

/// Bounded in-memory event log shown in Diagnostics. Never written to disk.
public final class DiagnosticsLog: @unchecked Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let category: String
        public let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 200) { self.capacity = capacity }

    public func record(_ category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(date: Date(), category: category, message: Redactor.text(message)))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
