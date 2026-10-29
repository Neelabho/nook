import NookCore
import SwiftUI

/// Renders assistant Markdown: block structure from `MarkdownParser`, inline styling from
/// `AttributedString(markdown:)`. Code blocks get their own copy button.
struct MarkdownView: View {
    let text: String
    let copy: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).font(.system(size: level <= 1 ? 15 : (level == 2 ? 14 : 13), weight: .semibold))
        case .paragraph(let text):
            Text(inline(text)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Nook.Palette.tertiaryText)
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12.5))
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + index).").foregroundStyle(Nook.Palette.tertiaryText).monospacedDigit()
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12.5))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Nook.Palette.tertiaryText).frame(width: 2)
                Text(inline(text)).font(.system(size: 12.5)).foregroundStyle(Nook.Palette.secondaryText)
            }
        case .rule:
            Divider().overlay(Nook.Palette.hairline)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, copy: copy)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    let copy: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 10, weight: .medium)).foregroundStyle(Nook.Palette.tertiaryText)
                Spacer()
                if let copy {
                    Button {
                        copy(code)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Nook.Palette.secondaryText)
                    .help("Copy code")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .scrollIndicators(.automatic)
        }
        // Code stays on a deep, near-opaque card for legibility (inside the shared glass language).
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.04).opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Nook.Palette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Code block\(language.map { " in \($0)" } ?? "")")
    }
}
