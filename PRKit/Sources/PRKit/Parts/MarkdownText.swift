import PRKitCore
import PRKitDesign
import SwiftUI

/// Markdown drawn as GitHub draws it: paragraphs, headings, nested bullet, numbered and task lists, fenced code and
/// tables that scroll sideways when wide, quotes, rules, images and `<details>` sections that open in place, with bold,
/// italic, strikethrough, `code` and links inside them. The one renderer for descriptions, comments and chat; each block
/// is selectable text in the font around it.
public struct MarkdownText: View {
    public let blocks: [MarkdownBlock]
    /// For small text, whose headings would otherwise tower over it.
    private let headingFont: Font?
    private let onCheckbox: ((Int, Bool) -> Void)?
    /// By block: which checkbox of the text it is, counting from 0, as the Worker counts them.
    private let checkboxes: [Int: Int]
    /// Room kept clear beside the first block only, for buttons over its top corner: the rest uses the full width.
    private let firstBlockInset: CGFloat
    /// Whether its words can be selected. A chat bubble on the phone turns it off: there a long press is the bubble's
    /// Copy, for the whole message, where selection took one paragraph at a time.
    private let isSelectable: Bool
    /// The `<details>` sections opened.
    @State private var folds = FoldSet()

    public init(
        _ source: String, headingFont: Font? = nil, firstBlockInset: CGFloat = 0,
        onCheckbox: ((Int, Bool) -> Void)? = nil, isSelectable: Bool = true
    ) {
        self.isSelectable = isSelectable
        let parsed = MarkdownBlocks.parse(source)
        blocks = parsed
        self.headingFont = headingFont
        self.firstBlockInset = firstBlockInset
        self.onCheckbox = onCheckbox
        checkboxes = Dictionary(uniqueKeysWithValues: parsed.flatMap(\.flattened).filter(Self.isCheckbox).enumerated()
            .map { ($1.id, $0) })
    }

    private static func isCheckbox(_ block: MarkdownBlock) -> Bool {
        guard case .listItem = block.kind else {
            return false
        }
        return MarkdownBlockView.checkedState(block) != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, context: context)
                    .padding(.trailing, block.id == blocks.first?.id ? firstBlockInset : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectable(isSelectable)
    }

    private var context: MarkdownBlockView.Context {
        .init(headingFont: headingFont, checkboxes: checkboxes, onCheckbox: onCheckbox, folds: folds)
    }
}

/// One block of `MarkdownText`, and the blocks inside it.
private struct MarkdownBlockView: View {
    struct Context {
        let headingFont: Font?
        let checkboxes: [Int: Int]
        let onCheckbox: ((Int, Bool) -> Void)?
        let folds: FoldSet
    }

    let block: MarkdownBlock
    let context: Context

    /// `PRMarkdown.clean` draws a task as one of these. Nil for an ordinary list item.
    static func checkedState(_ block: MarkdownBlock) -> Bool? {
        switch block.content.characters.first {
        case "☐": false
        case "☑︎": true
        default: nil
        }
    }

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
        case .heading(let level):
            Text(block.content)
                .font(context.headingFont ?? (level <= 2 ? .appHeadline : .appSubheadline.weight(.semibold)))
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth):
            listItem(marker: marker)
                .padding(.leading, CGFloat(depth - 1) * MarkdownStyle.indent)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.content)
                    .diffCodeFont(step: Font.appleSize(.footnote) - DiffFont.standard.size)
                    .fixedSize()
                    .padding(Space.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: Radius.md))
        case .quote:
            Text(block.content)
                .foregroundStyle(.secondary)
                .padding(.leading, MarkdownStyle.quoteInset)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: MarkdownStyle.quoteBar)
                }
        case .rule:
            Divider()
        case let .table(table):
            MarkdownTableView(table: table)
        case let .image(url):
            MarkdownImage(url: url, alt: String(block.content.characters))
        case let .details(inner):
            details(inner)
        }
    }

    @ViewBuilder private func listItem(marker: String) -> some View {
        if let onCheckbox = context.onCheckbox, let index = context.checkboxes[block.id],
           let isChecked = Self.checkedState(block) {
            Button { onCheckbox(index, !isChecked) } label: {
                HStack(alignment: .firstTextBaseline, spacing: MarkdownStyle.markerGap) {
                    Image(isChecked ? AppIcon.taskDone : AppIcon.taskOpen)
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
            HStack(alignment: .firstTextBaseline, spacing: MarkdownStyle.markerGap) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(block.content)
            }
        }
    }

    /// GitHub's fold: the summary, a chevron, and what it holds once opened.
    private func details(_ inner: [MarkdownBlock]) -> some View {
        let id = "markdown-details-\(block.id)"
        let isOpen = context.folds.isFlipped(id)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button { context.folds.toggle(id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: MarkdownStyle.markerGap) {
                    PRChevron(isCollapsed: !isOpen)
                    Text(block.content)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "open" : "closed")
            .accessibilityIdentifier(id)
            if isOpen {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(inner) { MarkdownBlockView(block: $0, context: context) }
                }
                .padding(.leading, MarkdownStyle.indent)
                .transition(.fold)
            }
        }
    }
}

/// A GitHub table: a header on the fill, a hairline between rows, each column aligned as its `:---:` says. Wider than
/// the text, it scrolls sideways; a long cell wraps at `MarkdownStyle.tableCellMaxWidth`.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.header, isHeader: true)
                ForEach(table.rows.indices, id: \.self) { index in
                    Divider()
                    row(table.rows[index], isHeader: false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(Color.line, lineWidth: PRStyle.hairline)
            )
            .clipShape(.rect(cornerRadius: Radius.sm, style: .continuous))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityIdentifier("markdown-table")
    }

    private func row(_ cells: [AttributedString], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, words in
                CappedWidth(maxWidth: MarkdownStyle.tableCellMaxWidth) {
                    Text(words)
                        .fontWeight(isHeader ? .semibold : nil)
                        .multilineTextAlignment(textAlignment(column))
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                // Each cell fills its row and column, so the header's fill has no gaps.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(column))
                .background(isHeader ? Color.groundFill : Color.clear)
                .gridColumnAlignment(gridAlignment(column))
            }
        }
    }

    private func alignment(_ column: Int) -> MarkdownTable.Alignment {
        table.alignments.indices.contains(column) ? table.alignments[column] : .leading
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func gridAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// An image on its own line, as wide as the text and no taller than `MarkdownStyle.imageMaxHeight`; its alt text while
/// it loads and when it can't be read (a private repo's attachment needs GitHub's sign-in).
private struct MarkdownImage: View {
    let url: URL
    let alt: String

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: AppMotion.swap)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: MarkdownStyle.imageMaxHeight, alignment: .leading)
                    .clipShape(.rect(cornerRadius: Radius.sm, style: .continuous))
                    .accessibilityLabel(alt)
            } else {
                Label(alt.isEmpty ? "Image" : alt, systemImage: AppIcon.attachPhoto.symbol)
                    .labelStyle(.iconText)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Its view at its own width up to `maxWidth`, and wrapped to `maxWidth` past it, with the height that takes. A table in
/// a sideways scroll offers no width, so a cell's words would otherwise be measured on one line and drawn on several.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else {
            return .zero
        }
        let width = self.width(view, proposal)
        return CGSize(width: width, height: view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func width(_ view: LayoutSubview, _ proposal: ProposedViewSize) -> CGFloat {
        let ideal = view.sizeThatFits(.unspecified).width
        return min(ideal, maxWidth, proposal.width ?? .infinity)
    }
}

extension View {
    /// Text selection on or off, as a value.
    @ViewBuilder func selectable(_ isOn: Bool) -> some View {
        if isOn {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
