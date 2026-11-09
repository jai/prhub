import PRKitCore
import PRKitDesign
import Foundation

/// Markdown as blocks the app can draw, GitHub's flavour: Foundation parses it, and each paragraph, heading, list item,
/// code block, quote, rule, table, image or `<details>` section keeps its inline styling (bold, italic, strikethrough,
/// `code`, links) in `content`.
public struct MarkdownBlock: Equatable, Identifiable {
    public enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `marker` is "•" or "3."; `depth` is 1 for a top-level item.
        case listItem(marker: String, depth: Int)
        case code
        case quote
        case rule
        case table(MarkdownTable)
        /// A paragraph that is only an image: `content` is its alt text.
        case image(URL)
        /// `<details>` with its `<summary>` as `content`: the blocks inside show once it is opened.
        case details([MarkdownBlock])
    }

    public var id: Int
    public var kind: Kind
    public var content: AttributedString

    /// This block and every block inside it, in reading order.
    var flattened: [MarkdownBlock] {
        guard case let .details(inner) = kind else {
            return [self]
        }
        return [self] + inner.flatMap(\.flattened)
    }
}

/// A GitHub table: its columns' alignment, the header row and the rows under it, each cell with its inline styling.
public struct MarkdownTable: Equatable {
    public enum Alignment: Equatable {
        case leading, center, trailing
    }

    public var alignments: [Alignment]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]
}

public enum MarkdownBlocks {
    /// Every block of `source`, in order; text Foundation cannot read at all is one plain paragraph. Ids count up through
    /// the blocks inside a `<details>` too, so each is unique.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var nextID = 0
        return parse(source, nextID: &nextID)
    }

    private static func parse(_ source: String, nextID: inout Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for part in DetailsSplit.parts(of: source) {
            switch part {
            case let .markdown(text):
                blocks += parseMarkdown(text, nextID: &nextID)
            case let .details(summary, inner):
                let id = nextID
                nextID += 1
                let title = parseMarkdown(summary, nextID: &nextID).first?.content ?? AttributedString(summary)
                blocks.append(MarkdownBlock(id: id, kind: .details(parse(inner, nextID: &nextID)), content: title))
            }
        }
        return blocks
    }

    private static func parseMarkdown(_ source: String, nextID: inout Int) -> [MarkdownBlock] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            defer { nextID += 1 }
            return [MarkdownBlock(id: nextID, kind: .paragraph, content: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        var tables: [Int: Int] = [:]
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var content = AttributedString(parsed[range])
            if let cell = TableCell(intent) {
                if let index = tables[cell.table] {
                    blocks[index].add(cell, content)
                } else {
                    tables[cell.table] = blocks.count
                    var block = MarkdownBlock(id: nextID, kind: .table(cell.empty), content: AttributedString())
                    nextID += 1
                    block.add(cell, content)
                    blocks.append(block)
                }
                continue
            }
            var kind = kind(of: intent)
            if kind == .paragraph, let url = onlyImage(content) {
                kind = .image(url)
            }
            if kind == .code {
                // A fence's last line ends in a newline, which would draw as an empty line.
                while content.characters.last?.isNewline == true {
                    content.characters.removeLast()
                }
            }
            blocks.append(MarkdownBlock(id: nextID, kind: kind, content: content))
            nextID += 1
        }
        return blocks
    }

    /// The image's address when the paragraph is one image and nothing else but space.
    private static func onlyImage(_ content: AttributedString) -> URL? {
        let images = Set(content.runs.compactMap(\.imageURL))
        let others = content.runs.filter { $0.imageURL == nil }
            .contains { !String(content[$0.range].characters).allSatisfy(\.isWhitespace) }
        return images.count == 1 && !others ? images.first : nil
    }

    /// Its components run from the block itself outwards: a list item's own list is the first list after it.
    private static func kind(of intent: PresentationIntent?) -> MarkdownBlock.Kind {
        let kinds = intent?.components.map(\.kind) ?? []
        let depth = kinds.filter { $0 == .orderedList || $0 == .unorderedList }.count
        for (index, kind) in kinds.enumerated() {
            switch kind {
            case .header(let level):
                return .heading(level: level)
            case .codeBlock:
                return .code
            case .thematicBreak:
                return .rule
            case .listItem(let ordinal):
                let ordered = kinds[(index + 1)...].first { $0 == .orderedList || $0 == .unorderedList } == .orderedList
                return .listItem(marker: ordered ? "\(ordinal)." : "•", depth: max(depth, 1))
            case .blockQuote:
                return .quote
            default:
                continue
            }
        }
        return .paragraph
    }
}

/// Where a run sits in a table: which table, which row (nil for the header) and which column.
private struct TableCell {
    let table: Int
    let row: Int?
    let column: Int
    let alignments: [MarkdownTable.Alignment]

    init?(_ intent: PresentationIntent?) {
        var column: Int?
        var row: Int?
        var isHeader = false
        var table: (Int, [MarkdownTable.Alignment])?
        for component in intent?.components ?? [] {
            switch component.kind {
            case let .tableCell(index): column = index
            case let .tableRow(index): row = index
            case .tableHeaderRow: isHeader = true
            case let .table(columns):
                table = (component.identity, columns.map { column in
                    switch column.alignment {
                    case .center: .center
                    case .right: .trailing
                    default: .leading
                    }
                })
            default: continue
            }
        }
        guard let column, let table, isHeader || row != nil else {
            return nil
        }
        self.table = table.0
        self.alignments = table.1
        self.row = isHeader ? nil : row
        self.column = column
    }

    var empty: MarkdownTable {
        MarkdownTable(alignments: alignments, header: [], rows: [])
    }
}

private extension MarkdownBlock {
    /// Puts a cell's words in its place, growing the table to reach it.
    mutating func add(_ cell: TableCell, _ words: AttributedString) {
        guard case var .table(table) = kind else {
            return
        }
        let width = table.alignments.count
        func place(_ row: inout [AttributedString]) {
            while row.count < max(width, cell.column + 1) {
                row.append(AttributedString())
            }
            row[cell.column] = words
        }
        if let index = cell.row {
            // Foundation counts the header as row 0.
            let rowIndex = max(index - 1, 0)
            while table.rows.count <= rowIndex {
                table.rows.append([])
            }
            place(&table.rows[rowIndex])
        } else {
            place(&table.header)
        }
        kind = .table(table)
    }
}

/// Markdown with its `<details>` sections taken out: GitHub's way to fold a long part of a description. A section's
/// `<summary>` is its title; sections can nest.
enum DetailsSplit {
    enum Part: Equatable {
        case markdown(String)
        case details(summary: String, body: String)
    }

    static func parts(of source: String) -> [Part] {
        let open = /(?i)<details\b[^>]*>/
        let close = /(?i)<\/details\s*>/
        var parts: [Part] = []
        var rest = Substring(source)
        while let start = rest.firstMatch(of: open) {
            // The matching close: one deeper for each <details> opened on the way.
            var depth = 1
            var cursor = start.range.upperBound
            var end: Range<Substring.Index>?
            while depth > 0 {
                let nextOpen = rest[cursor...].firstMatch(of: open)
                guard let nextClose = rest[cursor...].firstMatch(of: close) else {
                    break
                }
                if let nextOpen, nextOpen.range.lowerBound < nextClose.range.lowerBound {
                    depth += 1
                    cursor = nextOpen.range.upperBound
                } else {
                    depth -= 1
                    cursor = nextClose.range.upperBound
                    end = nextClose.range
                }
            }
            guard depth == 0, let end else {
                break
            }
            parts.append(.markdown(String(rest[..<start.range.lowerBound])))
            var body = String(rest[start.range.upperBound..<end.lowerBound])
            var summary = "Details"
            if let found = body.firstMatch(of: /(?is)<summary\b[^>]*>(.*?)<\/summary\s*>/) {
                summary = String(found.1).trimmingCharacters(in: .whitespacesAndNewlines)
                body.removeSubrange(found.range)
            }
            parts.append(.details(summary: summary, body: body))
            rest = rest[end.upperBound...]
        }
        parts.append(.markdown(String(rest)))
        return parts.filter { $0 != .markdown("") }
    }
}

extension String {
    /// The text as it reads once its inline Markdown is applied — `**bold**` is "bold", `[label](url)` is "label" —
    /// with its lines kept: for one-line previews, which show no styling.
    public var withoutMarkdown: String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: self, options: options) else {
            return self
        }
        return String(parsed.characters)
    }
}
