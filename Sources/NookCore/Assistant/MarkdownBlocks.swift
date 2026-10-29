import Foundation

/// Block-level Markdown structure for assistant replies. Inline styling (bold, code spans, links)
/// is left to `AttributedString(markdown:)` in the view layer.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, isClosed: Bool)
    case bulletList([String])
    case orderedList(start: Int, items: [String])
    case quote(String)
    case rule
}

public enum MarkdownParser {
    /// Parses complete or still-streaming Markdown. An unterminated code fence becomes an
    /// open code block so partial replies render sensibly while they stream.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var orderedStart = 1
        var quote: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false
        var fence = "```"

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets = [] }
            if !ordered.isEmpty { blocks.append(.orderedList(start: orderedStart, items: ordered)); ordered = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushLists(); flushQuote() }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix(fence) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: fence.prefix(1).description)).isEmpty {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n"), isClosed: true))
                    codeLines = []; codeLanguage = nil; inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let marker = trimmed.hasPrefix("```") ? "`" : "~"
                let count = trimmed.prefix { String($0) == marker }.count
                fence = String(repeating: marker, count: count)
                let lang = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                inCode = true
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushLists()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph(); flushQuote()
                if !ordered.isEmpty { blocks.append(.orderedList(start: orderedStart, items: ordered)); ordered = [] }
                bullets.append(item)
                continue
            }

            if let (number, item) = orderedItem(trimmed) {
                flushParagraph(); flushQuote()
                if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets = [] }
                if ordered.isEmpty { orderedStart = number }
                ordered.append(item)
                continue
            }

            // Continuation of a list item (indented line).
            if line.hasPrefix("  ") || line.hasPrefix("\t") {
                if !bullets.isEmpty { bullets[bullets.count - 1] += " " + trimmed; continue }
                if !ordered.isEmpty { ordered[ordered.count - 1] += " " + trimmed; continue }
            }

            flushLists(); flushQuote()
            paragraph.append(trimmed)
        }

        if inCode {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n"), isClosed: false))
        }
        flushAll()
        return blocks
    }

    static func parseHeading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    static func orderedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    /// All fenced code blocks, for "copy code" actions.
    public static func codeBlocks(in text: String) -> [String] {
        parse(text).compactMap { if case .code(_, let code, _) = $0 { return code } else { return nil } }
    }
}
