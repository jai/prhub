import PRKitCore
import PRKitDesign
import Foundation

/// An agent's Markdown as blocks the app can draw: Foundation parses it, and each paragraph, heading, list item, code
/// block, quote or rule keeps its inline styling — bold, italic, `code`, links — in `content`.
public struct MarkdownBlock: Equatable, Identifiable {
    public enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `marker` is "•" or "3."; `depth` is 1 for a top-level item.
        case listItem(marker: String, depth: Int)
        case code
        case quote
        case rule
    }

    public var id: Int
    public var kind: Kind
    public var content: AttributedString
}

public enum MarkdownBlocks {
    /// Every block of `source`, in order; text Foundation cannot read at all is one plain paragraph.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let content = AttributedString(parsed[range])
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind(of: intent), content: content))
        }
        return blocks
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
