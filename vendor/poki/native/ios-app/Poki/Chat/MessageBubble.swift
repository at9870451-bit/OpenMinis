// MessageBubble is from Mackarous/ConversationUI (commit e77c69e,
// Sources/ConversationUI/MessageBubble.swift), Copyright (c) 2024 Andrew Mackarous, MIT License. See
// THIRD_PARTY_NOTICES.md. Changed: Poki's message kinds, the tail corner on the last bubble of a run,
// 60 pt kept free on the far side, and the colours: an outside agent's request in ink, and for
// ESP-376 your bubble in Poki's blue and Poki's words in a white bubble with a soft shadow; in your
// bubble the apps you named show as capsules, as in the message field.
import SwiftUI
import UIKit

struct MessageBubble: View {
    /// Poki's words, yours, or an outside agent's request to Poki.
    enum Direction { case incoming, outgoing, guest }
    var direction: Direction
    var text: String
    /// The last bubble of its run has the small corner on its side.
    var tail: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var verticalInset = 13.0
    @ScaledMetric(relativeTo: .body) private var horizontalInset = 18.0
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            if direction != .incoming {
                Spacer(minLength: typeSize.isAccessibilitySize ? 16 : .messageInsetPadding)
            }
            if direction == .incoming {
                answer
                    .font(.body)
                    .tint(Tint.blueText)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, min(18, verticalInset))
                    .padding(.horizontal, min(24, horizontalInset))
                    .pokiBubble(tail: tail)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                    // A table takes the row's width before the space beside it, so it scrolls sideways
                    // only when it is wider than the bubble can be.
                    .layoutPriority(blocks.contains { if case .table = $0 { true } else { false } } ? 1 : 0)
                Spacer(minLength: typeSize.isAccessibilitySize ? 16 : .messageInsetPadding)
            } else {
                (direction == .outgoing ? withCapsules : Text(rendered))
                    .font(.body)
                    .accessibilityLabel(Text(verbatim: text))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(direction == .guest ? Tint.onSolid : Color.white)
                    .padding(.vertical, min(18, verticalInset))
                    .padding(.horizontal, min(24, horizontalInset))
                    .background(direction == .guest ? Tint.solid : Tint.blue, in: shape)
                    // The bubble is one flat layer with its own outline, so the lifted copy of it (the
                    // long press) is cut to the same outline and the small corner stays where it is.
                    .clipShape(shape)
                    .compositingGroup()
                    .contentShape(.contextMenuPreview, shape)
                    .contentShape(.interaction, shape)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 320, alignment: .trailing)
            }
        }
        .transaction { if direction == .incoming { $0.animation = nil } }
    }

    private var blocks: [AnswerBlocks.Block] { AnswerBlocks.blocks(text) }

    /// Poki's words: one text, or the text around the answer's tables.
    @ViewBuilder private var answer: some View {
        let parts = blocks
        if parts.count == 1, case .text(let words) = parts[0] {
            Text(words)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parts.indices, id: \.self) { i in
                    switch parts[i] {
                    case .text(let words): Text(words)
                    case .table(let alignments, let rows): AnswerTable(alignments: alignments, rows: rows)
                    }
                }
            }
        }
    }

    private var rendered: AttributedString {
        direction == .incoming ? AnswerMarkdown.render(text) : AttributedString(text)
    }

    /// Your words with each app's name as its capsule; the words themselves are what was sent, and
    /// what Copy copies.
    private var withCapsules: Text {
        let segments = CapsuleText.segments(text)
        guard segments.contains(where: { if case .app = $0 { true } else { false } }) else { return Text(rendered) }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
        return segments.reduce(Text(verbatim: "")) { line, segment in
            switch segment {
            case .text(let words):
                return line + Text(verbatim: words)
            case .app(let app, let words):
                let data = PillTextAttachmentData(app: app, text: words, font: font, onAccent: true)
                guard let image = PillView.image(data, scale: displayScale, dark: scheme == .dark) else { return line + Text(verbatim: words) }
                return line + Text(Image(uiImage: image)).baselineOffset(data.baselineOffset)
            }
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: .cornerRadius,
                               bottomTrailingRadius: tail ? .tailRadius : .cornerRadius,
                               topTrailingRadius: .cornerRadius, style: .continuous)
    }

    private func copyButton(copy: @escaping () -> Void) -> some View {
        Button(action: copy) {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

@MainActor
private enum AnswerMarkdown {
    private static let pendingLink = URL(string: "poki-pending-link:")!
    /// Each answer is parsed once: the conversation redraws on every key typed in the message field.
    private static var cache: [String: AttributedString] = [:]

    static func render(_ source: String) -> AttributedString {
        if let done = cache[source] { return done }
        let result = parse(source)
        if cache.count >= 300 { cache.removeAll(keepingCapacity: true) }
        cache[source] = result
        return result
    }

    private static func parse(_ source: String) -> AttributedString {
        let source = stableMarkdown(source)
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return AttributedString(source)
        }
        var result = AttributedString()
        var block: Int?
        var lastItem: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            if identity != block {
                if !result.characters.isEmpty { result.append(AttributedString("\n")) }
                block = identity
                let lists = components.filter {
                    switch $0.kind { case .orderedList, .unorderedList: true; default: false }
                }
                if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }) {
                    result.append(AttributedString(String(repeating: "  ", count: max(0, lists.count - 1))))
                    if item.identity != lastItem, case .listItem(let ordinal) = item.kind {
                        let ordered = lists.first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                        result.append(AttributedString(ordered ? "\(ordinal). " : "• "))
                    }
                    lastItem = item.identity
                } else {
                    lastItem = nil
                }
                if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                    result.append(AttributedString("▎ "))
                }
            }
            for component in components {
                switch component.kind {
                case .header:
                    piece.font = .body.weight(.semibold)
                case .codeBlock:
                    piece.font = .body.monospaced()
                case .blockQuote:
                    piece.foregroundColor = .secondary
                case .thematicBreak:
                    piece = AttributedString("────────")
                    piece.foregroundColor = .secondary
                default: break
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true { piece.font = .body.monospaced() }
            if run.link == pendingLink {
                piece.link = nil
                piece.foregroundColor = Tint.blueText
            }
            result.append(piece)
        }
        return result
    }

    private static func stableMarkdown(_ source: String) -> String {
        var fence: String?
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.dropFirst(open.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                } else if !trimmed.isEmpty, trimmed.count < open.count, trimmed.allSatisfy({ $0 == open.first }) {
                    return ""
                }
                return line
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                return line
            }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return "" }
                return cells.filter { !$0.isEmpty }.map(stableInline).joined(separator: "  ·  ") + "  "
            }
            if ["-", "--", "+", "`", "``", "~", "~~"].contains(trimmed) { return "" }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "*" || $0 == "_" || $0 == " " }) {
                return line
            }
            return stableInline(line)
        }.joined(separator: "\n")
    }

    private struct Delimiter {
        var character: Character
        var count: Int
        var text: String { String(repeating: String(character), count: count) }
    }

    // Complete only the display copy. The next token must not turn literal markers into styled words.
    private static func stableInline(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        var open: [Delimiter] = []
        var code: Int?
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if let count = code {
                if char == "`" {
                    let end = chars[i...].prefix(while: { $0 == char }).count + i
                    if end - i == count { code = nil }
                    if end == chars.count, end - i < count { break }
                    result += String(chars[i..<end])
                    i = end
                } else {
                    result.append(char)
                    i += 1
                }
                continue
            }
            if char == "\\" {
                if i + 1 < chars.count { result += String(chars[i...i + 1]); i += 2 } else { i += 1 }
                continue
            }
            if char == "[" || (char == "!" && i + 1 < chars.count && chars[i + 1] == "[") {
                let start = i + (char == "!" ? 2 : 1)
                let close = chars[start...].firstIndex(of: "]")
                let label = String(chars[start..<(close ?? chars.count)])
                if let close, close + 1 < chars.count, chars[close + 1] == "(" {
                    var depth = 1
                    var end = close + 2
                    while end < chars.count, depth > 0 {
                        if chars[end] == "(" { depth += 1 }
                        if chars[end] == ")" { depth -= 1 }
                        end += 1
                    }
                    if depth == 0 {
                        result += "[" + stableInline(label) + String(chars[close..<end])
                        i = end
                        continue
                    }
                }
                if !label.isEmpty { result += "[" + stableInline(label) + "](\(pendingLink.absoluteString))" }
                i = close.map { $0 + 1 } ?? chars.count
                if i < chars.count, chars[i] == "(" { i = chars.count }
                continue
            }
            if char == "`" || char == "*" || char == "_" {
                let end = chars[i...].prefix(while: { $0 == char }).count + i
                let count = end - i
                if char == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber,
                   end < chars.count, chars[end].isLetter || chars[end].isNumber {
                    result += String(chars[i..<end]); i = end; continue
                }
                if char == "`" {
                    if end < chars.count { code = count; result += String(chars[i..<end]) }
                } else if let last = open.last, last.character == char, i > 0, !chars[i - 1].isWhitespace {
                    if count >= last.count {
                        result += last.text
                        open.removeLast()
                        if count > last.count, end < chars.count {
                            let extra = Delimiter(character: char, count: count - last.count)
                            result += extra.text
                            open.append(extra)
                        }
                    } else if end < chars.count {
                        result += String(chars[i..<end])
                    }
                } else if end < chars.count, !chars[end].isWhitespace {
                    let delimiter = Delimiter(character: char, count: count)
                    result += delimiter.text
                    open.append(delimiter)
                } else if end < chars.count {
                    result += String(chars[i..<end])
                }
                i = end
                continue
            }
            result.append(char)
            i += 1
        }
        if let code { result += String(repeating: "`", count: code) }
        for delimiter in open.reversed() { result += delimiter.text }
        return result
    }

    /// One table cell: its words with their inline styles, completed as a line of text is while it streams.
    static func cell(_ source: String) -> AttributedString {
        let source = stableInline(source)
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(source)
        }
        var result = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true { piece.font = .subheadline.monospaced() }
            if run.link == pendingLink {
                piece.link = nil
                piece.foregroundColor = Tint.blueText
            }
            result.append(piece)
        }
        return result
    }
}

/// An answer cut into its text and its tables. A run of lines that start with `|`, outside code, is a
/// table once its second line is a delimiter row (`| --- | :---: |`). While the answer streams, the
/// table it is becoming shows as soon as its first line does, and a row being written shows the words
/// it has so far: a pipe never shows, and nothing jumps from text into a table. A finished answer
/// whose last row has no closing pipe or newline still shows that whole row.
@MainActor
private enum AnswerBlocks {
    enum Block {
        case text(AttributedString)
        case table([RawTableColumnAlignment], [RawTableRow])
    }

    /// Each answer is cut once: the conversation redraws on every key typed in the message field.
    private static var cache: [String: [Block]] = [:]

    static func blocks(_ source: String) -> [Block] {
        if let done = cache[source] { return done }
        let result = split(source)
        if cache.count >= 300 { cache.removeAll(keepingCapacity: true) }
        cache[source] = result
        return result
    }

    private static func split(_ source: String) -> [Block] {
        guard source.contains("|") else { return [.text(AnswerMarkdown.render(source))] }
        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = []
        var words: [String] = []
        func endWords() {
            let text = words.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(AnswerMarkdown.render(text))) }
            words = []
        }
        var fence: String?
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.dropFirst(open.count).allSatisfy(\.isWhitespace) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
            } else if trimmed.hasPrefix("|") {
                var end = i
                while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
                let run = lines[i..<end].map { $0.trimmingCharacters(in: .whitespaces) }
                // The source's last line may still be being written; a run followed only by the newline
                // that ended its last line may still get its delimiter row.
                let writing = end == lines.count
                let last = writing || (end == lines.count - 1 && lines[end].isEmpty)
                switch table(run, writing: writing, last: last) {
                case .table(let alignments, let rows):
                    endWords()
                    blocks.append(.table(alignments, rows))
                    i = end
                    continue
                case .notYet:
                    endWords()
                    i = end
                    continue
                case .text:
                    break
                }
                words += lines[i..<end]
                i = end
                continue
            }
            words.append(lines[i])
            i += 1
        }
        endWords()
        return blocks
    }

    private enum Run {
        case table([RawTableColumnAlignment], [RawTableRow])
        /// The first cell has no words yet.
        case notYet
        /// Not a table: the lines stay text.
        case text
    }

    private static func table(_ run: [String], writing: Bool, last: Bool) -> Run {
        let header = cells(run[0])
        if run.count >= 2, let alignments = delimiter(run[1], columns: header.count) {
            var rows = [header]
            for (offset, line) in run.dropFirst(2).enumerated() {
                let row = cells(line)
                if writing, offset == run.count - 3, row.allSatisfy(\.isEmpty) { continue }
                rows.append(row)
            }
            return .table(inferred(alignments, rows: rows, writing: writing), rows.map { row in
                RawTableRow(cells: (0..<header.count).map { RawTableCell(content: AnswerMarkdown.cell($0 < row.count ? row[$0] : "")) })
            })
        }
        // A header row, perhaps still being written, waiting for its delimiter row.
        guard last, run.count == 1 || (writing && run.count == 2 && run[1].allSatisfy({ "|:- ".contains($0) })) else { return .text }
        guard header.contains(where: { !$0.isEmpty }) else { return .notYet }
        return .table(Array(repeating: .none, count: header.count),
                      [RawTableRow(cells: header.map { RawTableCell(content: AnswerMarkdown.cell($0)) })])
    }

    /// A line's cells, without the outer pipes. `\|` stays in its cell.
    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for char in body {
            if char == "|", !escaped {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(char)
            }
            escaped = char == "\\" && !escaped
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The columns' alignments from a delimiter row with one `---` per header cell; nil for any other line.
    private static func delimiter(_ line: String, columns: Int) -> [RawTableColumnAlignment]? {
        let parts = cells(line)
        guard parts.count == columns else { return nil }
        var alignments: [RawTableColumnAlignment] = []
        for part in parts {
            let dashes = part.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.right)
            case (true, false): alignments.append(.left)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    /// A column the delimiter row leaves unaligned is right-aligned when every value in it is a number:
    /// a price, an amount with its unit, a time. A dash or N/A says nothing either way, and neither does
    /// a cell still being written that has no digit yet.
    private static func inferred(_ alignments: [RawTableColumnAlignment], rows: [[String]], writing: Bool) -> [RawTableColumnAlignment] {
        alignments.enumerated().map { column, alignment in
            guard alignment == .none else { return alignment }
            var values: [String] = []
            for (r, row) in rows.enumerated().dropFirst() where column < row.count {
                let value = row[column]
                if ["", "-", "–", "—", "N/A", "n/a", "NA", "?"].contains(value) { continue }
                let open = writing && r == rows.count - 1 && column == row.count - 1
                if open && !value.contains(where: \.isNumber) { continue }
                values.append(value)
            }
            return !values.isEmpty && values.allSatisfy(isNumber) ? .right : .none
        }
    }

    private static func isNumber(_ value: String) -> Bool {
        let plain = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard plain.contains(where: \.isNumber) else { return false }
        let rest = plain.filter { !$0.isNumber && !$0.isWhitespace && !"$€£¥￥₩₹.,%+-−–~≈/:()×*".contains($0) }
        return rest.count <= 3
    }
}

/// A table in Poki's answer, in the GitHub theme's table style (Theme+GitHub.swift) on the system's
/// colours: as wide as its columns, or as wide as the bubble and scrolled sideways when it is wider.
private struct AnswerTable: View {
    var alignments: [RawTableColumnAlignment]
    var rows: [RawTableRow]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            table.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal, showsIndicators: false) { table }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollsSideways()
        }
    }

    private var table: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return TableView(columnAlignments: alignments, rows: rows)
            .font(.subheadline)
            .markdownTableBorderStyle(.init(.insideBorders, color: Color(.separator)))
            .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Color(.quaternarySystemFill), header: Color(.tertiarySystemFill)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(.separator), lineWidth: 1))
    }
}

extension CGFloat {
    static let cornerRadius: CGFloat = 22
    static let tailRadius: CGFloat = 7
    static let messageInsetPadding: CGFloat = 60
}

extension View {
    /// Poki's bubble (ESP-376): the card's white with a soft shadow in light; in dark the card's grey
    /// with a hairline, where a shadow does not show. The small corner sits on Poki's side.
    func pokiBubble(tail: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: tail ? .tailRadius : .cornerRadius,
                                           bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous)
        return background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(Tint.ring.opacity(0.5), lineWidth: 0.5))
            // One flat layer cut to its outline (as your bubble), under the shadow.
            .clipShape(shape)
            .compositingGroup()
            .shadow(color: Tint.bubbleShadow, radius: 6, y: 2)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.interaction, shape)
    }
}

/// The chat's greys. The boards draw iMessage's light colours, which are iOS's own system colours, so
/// these follow them (and dark mode) instead of fixed values.
enum ChatColor {
    /// #E9E9EB on the board (iMessage's incoming bubble): systemGray5, #E5E5EA.
    static let incoming = Color(.systemGray5)
    /// #8E8E93: times, "Delivered", the grey notes, values.
    static let secondary = Color(.systemGray)
    /// #6B6B70: a step not done yet (Site.text2 on the board).
    static let pending = Color(.secondaryLabel)
    /// #34C759.
    static let green = Color(.systemGreen)
    /// #D1D1D6: the message field's edge.
    static let fieldEdge = Color(.systemGray4)
    /// #A1A1A6: the placeholder.
    static let placeholder = Color(.placeholderText)
    /// #C6C6C8: the header's bottom line and the rows' separators.
    static let separator = Color(.opaqueSeparator)
}
