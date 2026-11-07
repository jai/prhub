import PRKitCore
import PRKitDesign
import SwiftUI

/// An agent's Markdown drawn as it reads: paragraphs, headings, nested bullet and numbered lists, code blocks, quotes
/// and rules, with bold, italic, `code` and links inside them. Each block is selectable text in the font around it.
public struct MarkdownText: View {
    public let blocks: [MarkdownBlock]
    /// For small text, whose headings would otherwise tower over it.
    private let headingFont: Font?
    private let onCheckbox: ((Int, Bool) -> Void)?
    /// By block: which checkbox of the text it is, counting from 0, as the Worker counts them.
    private let checkboxes: [Int: Int]
    /// Room kept clear beside the first block only, for buttons over its top corner: the rest uses the full width.
    private let firstBlockInset: CGFloat

    public init(
        _ source: String, headingFont: Font? = nil, firstBlockInset: CGFloat = 0,
        onCheckbox: ((Int, Bool) -> Void)? = nil
    ) {
        let parsed = MarkdownBlocks.parse(source)
        blocks = parsed
        self.headingFont = headingFont
        self.firstBlockInset = firstBlockInset
        self.onCheckbox = onCheckbox
        checkboxes = Dictionary(uniqueKeysWithValues: parsed.filter(Self.isCheckbox).enumerated().map {
            ($1.id, $0)
        })
    }

    private static func isCheckbox(_ block: MarkdownBlock) -> Bool {
        guard case .listItem = block.kind else {
            return false
        }
        return checkedState(block) != nil
    }

    /// `PRMarkdown.clean` draws a task as one of these. Nil for an ordinary list item.
    private static func checkedState(_ block: MarkdownBlock) -> Bool? {
        switch block.content.characters.first {
        case "☐": false
        case "☑︎": true
        default: nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                row(block)
                    .padding(.trailing, block.id == blocks.first?.id ? firstBlockInset : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
        case .heading(let level):
            Text(block.content)
                .font(headingFont ?? (level <= 2 ? .appHeadline : .appSubheadline.weight(.semibold)))
        case .listItem(let marker, let depth):
            Group {
                if let onCheckbox, let index = checkboxes[block.id], let isChecked = Self.checkedState(block) {
                    Button { onCheckbox(index, !isChecked) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                            // After the box and the space that follows it, so wrapped lines line up with the first.
                            let box = block.content.index(afterCharacter: block.content.startIndex)
                            let words = block.content[box...].characters.prefix(while: \.isWhitespace).count
                            Text(AttributedString(block.content[block.content.index(box, offsetByCharacters: words)...]))
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isChecked ? "checked" : "unchecked")
                    .accessibilityIdentifier("pr-checkbox-\(index)")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(block.content)
                    }
                }
            }
            .padding(.leading, CGFloat(depth - 1) * 18)
        case .code:
            Text(block.content)
                .font(.appFootnote.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
        case .quote:
            Text(block.content)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 3)
                }
        case .rule:
            Divider()
        }
    }
}
