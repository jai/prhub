import PRKitCore
import PRKitDesign
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The diff's colours and fixed measures, the same on the phone's table and the Mac's (`Phone/`, `Mac/`). What follows
/// the font is `DiffMetrics`.
enum DiffStyle {
    static let threadInset: CGFloat = 8
    static let lineInset: CGFloat = 6
    static let lineNumberGap = Space.sm
    static let selectedLine = PlatformColor.systemYellow.withAlphaComponent(0.32)

    static func background(_ kind: DiffDocument.Kind) -> PlatformColor {
        switch kind {
        case .added: .systemGreen.withAlphaComponent(0.18)
        case .removed: .systemRed.withAlphaComponent(0.18)
        case .hunk: .systemBlue.withAlphaComponent(0.14)
        case .file, .meta, .context: .clear
        }
    }
}

/// The diff's measures at a font and text size: the code, the file header one step bigger, and a header row that holds
/// a 44 pt viewed mark on the phone.
struct DiffMetrics {
    /// Apple's smallest tap target.
    static let minimumTapTarget: CGFloat = 44
    static let rowPadding: CGFloat = 2
    private static let headerPadding = Space.sm

    let font: DiffFont
    let scale: CGFloat
    let code: PlatformFont
    let headerPath: PlatformFont
    let headerChange: PlatformFont
    let rowHeight: CGFloat
    let fileHeaderHeight: CGFloat
    /// One character of the code.
    let columnWidth: CGFloat
    let viewedSymbolSize: CGFloat
    let viewedTarget: CGFloat
    let chevronSymbolSize: CGFloat

    /// `scale` is the text size's: Dynamic Type's on the phone, View → Make Text Bigger's on the Mac.
    init(_ font: DiffFont, scale: CGFloat) {
        self.font = font
        self.scale = scale
        let (codeSize, headerSize) = Self.pointSizes(font, scale: scale)
        code = font.platformFont(points: codeSize)
        headerPath = font.platformFont(points: headerSize, isBold: true)
        headerChange = .monospacedDigitSystemFont(ofSize: headerSize, weight: .medium)
        rowHeight = ceil(code.diffLineHeight) + Self.rowPadding
        #if os(iOS)
            viewedTarget = max(Self.minimumTapTarget, ceil(headerPath.diffLineHeight) + Self.headerPadding * 2)
        #else
            viewedTarget = ceil(headerPath.diffLineHeight) + Self.headerPadding * 2
        #endif
        fileHeaderHeight = viewedTarget
        columnWidth = ("M" as NSString).size(withAttributes: [.font: code]).width
        viewedSymbolSize = (headerSize * 1.05).rounded()
        chevronSymbolSize = (headerSize * 0.8).rounded()
    }

    /// The code's size and the file header's at the text size `scale`: the header a step bigger than the code.
    static func pointSizes(_ font: DiffFont, scale: CGFloat) -> (code: CGFloat, header: CGFloat) {
        (font.size * scale, (font.size + DiffFont.headingStep) * scale)
    }

    func lineNumberWidth(digits: Int) -> CGFloat {
        ceil(CGFloat(digits) * columnWidth) + Space.xs
    }

    func gutterWidth(digits: Int) -> CGFloat {
        (lineNumberWidth(digits: digits) + DiffStyle.lineNumberGap) * 2
    }

    /// The code's room in a row `rowWidth` wide: what the line numbers and the insets leave.
    func codeWidth(inRow rowWidth: CGFloat, digits: Int) -> CGFloat {
        max(0, rowWidth - gutterWidth(digits: digits) - DiffStyle.lineInset * 2)
    }

    /// The file header's path for `text` in `width`: the header's size when it fits, else smaller, down to the code's
    /// size (a heading is never smaller than what it heads). A path still too long is cut from the front.
    func headerPath(fitting text: String, in width: CGFloat) -> PlatformFont {
        var fitted = headerPath
        while fitted.pointSize > code.pointSize,
              (text as NSString).size(withAttributes: [.font: fitted]).width > width
        {
            fitted = font.platformFont(points: max(fitted.pointSize - 1, code.pointSize), isBold: true)
        }
        return fitted
    }

    #if os(iOS)
        init(_ font: DiffFont, traits: UITraitCollection) {
            self.init(font, scale: Self.textScale(traits))
        }

        /// Dynamic Type's scale for body text at `traits`' text size: 1 at the default, Large.
        static func textScale(_ traits: UITraitCollection) -> CGFloat {
            let reference: CGFloat = 100
            return UIFontMetrics.default.scaledValue(for: reference, compatibleWith: traits) / reference
        }
    #else
        init(_ font: DiffFont) {
            self.init(font, scale: MacTextSize.codeScale)
        }
    #endif
}

/// Long lines wrapped in the code's room: at a word's end where the line has words, and wherever the row ends where it
/// has hardly a space (minified code). The rows that follow the first are set in past the line's own indentation, so a
/// wrapped line still reads as one line and the file's shape stays.
struct DiffWrap {
    /// How far past the code's own start a wrapped line's later rows begin, in columns.
    private static let hangingColumns = 2
    /// The rows shown of a line that opens cut (`DiffRows.cut`), over "Show full line". A file saved as one line is
    /// changed as two, the old and the new: twenty rows each and their two buttons are one phone screen, so the next
    /// file is a swipe away. On a wider screen the line's first piece ends before twenty rows do.
    static let shownRows = 20
    /// A room no line is too long for: a row drawn before its table has a width.
    static let unbounded: CGFloat = 1_000_000

    let metrics: DiffMetrics
    /// The code's room: `DiffMetrics.codeWidth(inRow:digits:)`.
    let width: CGFloat

    /// Whole characters that fit across.
    var columns: Int {
        max(1, Int(width / metrics.columnWidth))
    }

    /// A piece that needs no measuring: short enough for one row whatever it holds, a column kept spare.
    func isOneRow(line index: Int, piece: Int, of document: DiffDocument) -> Bool {
        document.byteCount(ofLine: index, piece: piece) < columns && document.isPlain(line: index, piece: piece)
    }

    /// About how many rows a piece wraps to, from its bytes alone: the table's guess until the piece is on screen.
    func estimatedRows(line index: Int, piece: Int, of document: DiffDocument) -> Int {
        let bytes = document.byteCount(ofLine: index, piece: piece)
        return max(1, (bytes + columns - 1) / columns)
    }

    func height(rows: Int) -> CGFloat {
        CGFloat(rows) * (metrics.rowHeight - DiffMetrics.rowPadding) + DiffMetrics.rowPadding
    }

    /// The row's height for text that measures `textHeight`: never less than a row of code.
    func height(fitting textHeight: CGFloat) -> CGFloat {
        max(metrics.rowHeight, ceil(textHeight) + DiffMetrics.rowPadding)
    }

    /// A piece as drawn. The first piece starts at the row's edge; a later one starts set in, as a wrapped row does.
    func text(line index: Int, piece: Int, of document: DiffDocument) -> NSAttributedString {
        let line = document.lines[index]
        // At most a quarter of the room: in the largest text a row holds a dozen characters.
        let indent = min(document.indentColumns(of: line) + Self.hangingColumns, columns / 4)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = document.isMinified(line: index, piece: piece) ? .byCharWrapping : .byWordWrapping
        style.headIndent = CGFloat(indent) * metrics.columnWidth
        style.firstLineHeadIndent = piece == 0 ? 0 : style.headIndent
        style.tabStops = []
        style.defaultTabInterval = CGFloat(DiffDocument.tabColumns) * metrics.columnWidth
        return NSAttributedString(
            string: document.text(ofLine: index, piece: piece),
            attributes: [.font: metrics.code, .paragraphStyle: style, .foregroundColor: PlatformColor.diffCode]
        )
    }

    /// A row's height, no more than `shownRows` of it for a line shown cut: as tall as that many rows of text are
    /// drawn, so the text fills its row and the numbers stay beside its first.
    func height(_ height: CGFloat, isCut: Bool) -> CGFloat {
        isCut ? min(height, self.height(fitting: CGFloat(Self.shownRows) * metrics.code.diffLineHeight)) : height
    }

    /// How `text` breaks, for the label that draws it: a label's own setting is what it follows.
    static func lineBreakMode(of text: NSAttributedString) -> NSLineBreakMode {
        guard text.length > 0,
              let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else {
            return .byWordWrapping
        }
        return style.lineBreakMode
    }

    static let lessTitle = "Show less"

    /// "Show full line (54 KB)", under the start of a very long line.
    static func restTitle(_ line: DiffDocument.Line) -> String {
        "Show full line (\(line.length.formatted(.byteCount(style: .file))))"
    }
}

extension PlatformColor {
    /// Code's own colour, set on wrapped text because an attributed string doesn't take its label's.
    static var diffCode: PlatformColor {
        #if os(iOS)
            .label
        #else
            .labelColor
        #endif
    }
}

extension PlatformFont {
    /// One line's height, the same on UIKit and AppKit.
    var diffLineHeight: CGFloat {
        #if os(iOS)
            lineHeight
        #else
            ascender - descender + leading
        #endif
    }
}

/// What the table can ask for. It holds these, not the session, so it only ever sees a diff and rows.
struct DiffActions {
    /// Which files and threads Jai has folded: it lives in the session, so it outlasts a switch of page.
    let folds: FoldSet
    let setViewed: (Bool, String) -> Void
    /// Hosted cells don't inherit SwiftUI's environment, and a PR link in a thread must stay in the app.
    let openURL: OpenURLAction
    let text: (DiffDocument.Line) -> Binding<String>
    let replyText: (PullRequestDetail.Thread) -> Binding<String?>
    /// A line was picked to comment on, or nil to stop. The box itself is the screen's, above the keyboard.
    let compose: (Int?) -> Void
    let closeNote: () -> Void
    /// The noted key line's tick, read by the note itself so a tick made in the panel shows under the line too.
    let isReviewed: (PRKeyLines.Item) -> Bool
    let setReviewed: (PRKeyLines.Item, Bool) -> Void
    /// Ask AI about a key line; nil when Ask is off.
    let explain: ((PRKeyLines.Item) -> Void)?
    /// The reader scrolled down the code (true) or back up. The phone's bars go and come with it.
    let setBarsHidden: (Bool) -> Void
    let setKeyboardUp: (Bool) -> Void
    /// What a pending comment's card asks for: its words to change, Delete, and Try again after a refusal.
    let pending: PRPendingActions
    let reply: (PullRequestDetail.Thread, String) async throws -> Void
    let setResolved: (PullRequestDetail.Thread, Bool) async throws -> Void
    /// The file at the top of the screen, by index, as the reader scrolls.
    let showsFileOnTop: (Int) -> Void
    /// "Show full line" on a very long line, by its index in the document.
    var showWholeLine: (Int) -> Void = { _ in }
}
