import SwiftUI
import UIKit

// Models answer in Markdown, so anywhere we show model prose we render it
// rather than printing the source. Block layout is done here; inline spans
// (**bold**, *italic*, `code`, links) go through Foundation's parser.

// MARK: - Blocks

/// The subset of Markdown a model actually emits in an answer.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [MarkdownListItem])
    case quote(String)
    case code(language: String?, body: String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct MarkdownListItem {
    var marker: String?
    var text: String
    var depth: Int
}

// MARK: - Parser

enum MarkdownParser {

    static func blocks(from source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [MarkdownListItem] = []
        var itemsOrdered = false

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.quote(text)) }
            quote = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(ordered: itemsOrdered, items: items)) }
            items = []
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList() }

        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code — consumed whole so its contents are never parsed.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushAll()
                let fence = String(line.prefix(3))
                let language = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1   // step over the closing fence
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    body: body.joined(separator: "\n")))
                continue
            }

            if line.isEmpty { flushAll(); i += 1; continue }

            if isHorizontalRule(line) {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let heading = heading(line) {
                flushAll()
                blocks.append(heading)
                i += 1
                continue
            }

            // A table needs its `|---|---|` divider on the next line.
            if line.hasPrefix("|"), i + 1 < lines.count,
               isTableDivider(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushAll()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            flushQuote()

            if let (item, ordered) = listItem(raw) {
                flushParagraph()
                if !items.isEmpty && ordered != itemsOrdered { flushList() }
                itemsOrdered = ordered
                items.append(item)
                i += 1
                continue
            }

            // An indented line under a bullet belongs to that bullet.
            if !items.isEmpty, raw.first == " " || raw.first == "\t" {
                items[items.count - 1].text += " " + line
                i += 1
                continue
            }

            flushList()
            paragraph.append(line)
            i += 1
        }

        flushAll()
        return blocks
    }

    /// `---`, `***` or `___` on a line of its own.
    static func isHorizontalRule(_ line: String) -> Bool {
        let glyphs = Set(line)
        for rule: Character in ["-", "*", "_"] where glyphs.isSubset(of: Set<Character>([rule, " ", "\t"])) {
            return line.filter { $0 == rule }.count >= 3
        }
        return false
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let text = rest
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func listItem(_ raw: String) -> (MarkdownListItem, Bool)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = min(indent / 2, 3)
        let line = raw.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            var text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            // Task-list syntax reads as noise on a phone.
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
                text = String(text.dropFirst(box.count))
            }
            return (MarkdownListItem(text: text, depth: depth), false)
        }

        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return (MarkdownListItem(marker: String(digits), text: text, depth: depth), true)
            }
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: \t".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Inline

    /// **bold**, *italic*, `code` and links, with the source characters removed.
    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(allowsExtendedAttributes: true,
                           interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)

        // Foundation marks inline code but leaves it looking like body text.
        let codeRuns = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
            return run.range
        }
        for range in codeRuns {
            attributed[range].font = .system(.footnote, design: .monospaced)
        }
        return attributed
    }
}

extension Text {
    /// For short model-written strings — a bullet, a definition, a heading.
    init(md text: String) {
        self.init(MarkdownParser.inline(text))
    }
}

// MARK: - Style

struct MarkdownStyle {
    var tint: Color = .brand
    var bodyFont: Font = .subheadline
    var bodyColor: Color = .primary
    var blockSpacing: CGFloat = 13
    var lineSpacing: CGFloat = 3.5

    /// Full-size prose, as in a brain answer.
    static let answer = MarkdownStyle()

    /// Supporting copy inside an already-titled card.
    static let note = MarkdownStyle(bodyColor: .secondary, blockSpacing: 10, lineSpacing: 3)
}

// MARK: - Renderer

struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    private let style: MarkdownStyle

    init(_ markdown: String, style: MarkdownStyle = .answer) {
        self.blocks = MarkdownParser.blocks(from: markdown)
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : gap(from: blocks[index - 1], to: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(style.tint)
        .textSelection(.enabled)
    }

    // MARK: Rhythm

    private func gap(from previous: MarkdownBlock, to next: MarkdownBlock) -> CGFloat {
        switch (previous, next) {
        case (.heading, _):        return 7                        // heading hugs its body
        case (_, .heading):        return style.blockSpacing + 7   // but gets air above
        case (_, .rule), (.rule, _): return style.blockSpacing + 3
        case (.list, .list):       return 7
        default:                   return style.blockSpacing
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            heading(level: level, text: text)

        case .paragraph(let text):
            prose(text)

        case .list(let ordered, let items):
            list(ordered: ordered, items: items)

        case .quote(let text):
            HStack(alignment: .top, spacing: 11) {
                Capsule().fill(style.tint.opacity(0.4)).frame(width: 3)
                prose(text).italic()
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let body):
            CodeBlock(language: language, source: body)

        case .table(let header, let rows):
            table(header: header, rows: rows)

        case .rule:
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.primary.opacity(0.14), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(md: text)
            .font(style.bodyFont)
            .foregroundStyle(style.bodyColor)
            .lineSpacing(style.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        let font: Font = level == 1 ? .title3.weight(.bold)
                       : level == 2 ? .headline
                       : .subheadline.weight(.semibold)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if level >= 2 {
                Capsule()
                    .fill(style.tint)
                    .frame(width: 3, height: level == 2 ? 15 : 12)
                    .alignmentGuide(.firstTextBaseline) { d in d.height + 1 }
            }
            Text(md: text)
                .font(font)
                .foregroundStyle(level >= 3 ? AnyShapeStyle(style.tint) : AnyShapeStyle(Color.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(ordered: Bool, items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(for: item, ordered: ordered, index: index)
                    Text(md: item.text)
                        .font(style.bodyFont)
                        .foregroundStyle(style.bodyColor)
                        .lineSpacing(style.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 15)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, ordered: Bool, index: Int) -> some View {
        if ordered {
            Text(item.marker ?? "\(index + 1)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(style.tint)
                .frame(width: 19, height: 19)
                .background(style.tint.opacity(0.14), in: Circle())
                .alignmentGuide(.firstTextBaseline) { d in d.height - 5 }
        } else if item.depth == 0 {
            Circle()
                .fill(style.tint)
                .frame(width: 5.5, height: 5.5)
                .alignmentGuide(.firstTextBaseline) { _ in 5.5 }
        } else {
            Circle()
                .strokeBorder(style.tint.opacity(0.6), lineWidth: 1.4)
                .frame(width: 5.5, height: 5.5)
                .alignmentGuide(.firstTextBaseline) { _ in 5.5 }
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(md: cell)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(style.tint)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(md: cell)
                            .font(.caption)
                            .foregroundStyle(style.bodyColor)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.hairline)
        }
    }
}

// MARK: - Code block

/// Scrolls sideways rather than wrapping, so indentation survives, and can be
/// copied in one tap — worth it when the answer is about code.
private struct CodeBlock: View {
    let language: String?
    let source: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text((language ?? "code").uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = source
                    Haptics.success()
                    withAnimation(.quick) { copied = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(copied ? Color.brand : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.hairline)
        }
    }
}
