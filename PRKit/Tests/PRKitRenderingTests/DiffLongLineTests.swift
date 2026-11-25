import Foundation
@testable import PRKit
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A line too long for the diff is read whole, in the diff's width: it wraps, its last characters are drawn inside its
/// row, and nothing scrolls sideways (a teammate's feedback, 2026-11-25: a README's paragraph, a long comment and a
/// dashboard saved as one line were cut at 160 columns with nothing to show the rest). On a phone's width, at the
/// default text size and a large one; the Mac's table is checked the same way.
@MainActor
struct DiffLongLineTests {
    private nonisolated static let width: CGFloat = 402
    private nonisolated static let prose = "+" + String(repeating: "A panel turns red when one request in a hundred fails. ", count: 12)
        + "END-OF-PARAGRAPH"
    private nonisolated static let code = "+            guard number < RetryPolicy.maximumAttempts, failure.kind != .declined, "
        + "failure.kind != .cancelled, !failure.isPermanent, clock.now < deadline else { return nil } // END-OF-CALL"
    private nonisolated static let minified = "+" + String(repeating: #"{"id":1,"type":"timeseries"},"#, count: 30) + "END-OF-JSON"

    @Test(arguments: [prose, code, minified], [CGFloat(12), 20])
    func aLongLinesLastCharactersAreDrawnInItsRow(line: String, size: CGFloat) throws {
        let table = try Table(lines: [line], fontSize: size)
        let row = try table.row(0)
        #expect(row.text == line, "the whole line, with no cut mark")
        #expect(row.text.hasSuffix(String(line.suffix(8))))
        #expect(row.labelFrame.maxX <= Self.width, "inside the screen's width")
        #expect(row.neededHeight <= row.labelFrame.height + 0.5, "every wrapped row of it is inside its row")
        #expect(row.neededHeight > table.metrics.rowHeight * 2, "the case this is for: it takes several rows")
        #expect(table.sidewaysRoom <= 0.5, "nothing to scroll sideways")
    }

    /// A wrapped line's numbers stay beside its first row, and a line that fits keeps the one fixed height.
    @Test func theNumbersStayBesideAWrappedLinesFirstRow() throws {
        let table = try Table(lines: [Self.prose, "+short"], fontSize: 12)
        let wrapped = try table.row(0)
        #expect(wrapped.numberFrame.height <= table.metrics.rowHeight)
        #expect(wrapped.numberIsAtTheTop)
        #expect(wrapped.height > table.metrics.rowHeight)
        #expect(try table.row(1).height == table.metrics.rowHeight)
    }

    /// Prose breaks between words: every wrapped row but the last ends at a space, never inside a word.
    @Test func proseWrapsBetweenWords() throws {
        let table = try Table(lines: [Self.prose], fontSize: 12)
        let wrap = try #require(table.container.wrap)
        let text = wrap.text(line: table.firstLine, piece: 0, of: table.container.document)
        let rows = Self.wrappedRows(of: text, width: wrap.width)
        #expect(rows.count > 3)
        for row in rows.dropLast() {
            #expect(row.hasSuffix(" "), "\(row.suffix(12))")
        }
    }

    /// Minified code has no words to break between: every row but the last is full, the first from the line's `+`.
    @Test func minifiedCodeFillsEveryRow() throws {
        let table = try Table(lines: [Self.minified], fontSize: 12)
        let wrap = try #require(table.container.wrap)
        let text = wrap.text(line: table.firstLine, piece: 0, of: table.container.document)
        let rows = Self.wrappedRows(of: text, width: wrap.width)
        #expect(rows.count > 3)
        #expect(rows[0].hasPrefix("+{") && rows[0].count >= wrap.columns - 1)
        #expect(Set(rows.dropFirst().dropLast().map(\.count)).count == 1, "each later row holds as much as the next")
    }

    /// A megabyte on one line opens as its first twenty rows with "Show full line" under them: no row holds the
    /// megabyte, so nothing lays it out at once, and the next file is a screen away.
    @Test func aMegabyteOnOneLineOpensAsItsFirstRows() throws {
        let line = "+" + String(repeating: #"{"id":1,"type":"timeseries","title":"Checkout requests"},"#, count: 19000)
        #expect(line.utf8.count > 1_000_000)
        let table = try Table(lines: [line], fontSize: 12)
        let rows = table.container.rows.files[0].rows
        #expect(rows == [.line(3), .line(table.firstLine), .rest(table.firstLine)], "the hunk, the start, the button")
        let start = try table.row(0)
        #expect(start.text.utf8.count <= DiffDocument.pieceBytes)
        let drawn = CGFloat(DiffWrap.shownRows) * table.metrics.code.diffLineHeight
        #expect(start.height == ceil(drawn) + DiffMetrics.rowPadding, "twenty rows of it")
        #expect(abs(start.neededHeight - drawn) <= 1, "the label draws those rows and no more, and they fill it")
    }

    /// With wrapping off the code scrolls sideways as it did, a long line cut with its mark.
    @Test func withWrappingOffALongLineScrollsSideways() throws {
        let table = try Table(lines: [Self.prose], fontSize: 12, wraps: false)
        let row = try table.row(0)
        #expect(row.text.hasSuffix("⋯"))
        #expect(row.height == table.metrics.rowHeight)
        #expect(table.sidewaysRoom > 0)
    }

    /// The text of each row `text` wraps to in `width`, as TextKit breaks it.
    private static func wrappedRows(of text: NSAttributedString, width: CGFloat) -> [String] {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var rows: [String] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            rows.append((text.string as NSString).substring(with: characters))
            glyph = NSMaxRange(range)
        }
        return rows
    }
}

/// One file's added lines in a diff table laid out on a phone's width.
@MainActor
private struct Table {
    struct Row {
        let text: String
        let height: CGFloat
        let labelFrame: CGRect
        /// What the label's text needs at the label's width.
        let neededHeight: CGFloat
        let numberFrame: CGRect
        let numberIsAtTheTop: Bool
    }

    let container: DiffTableContainer
    let metrics: DiffMetrics
    /// The document's index of the file's first code line.
    let firstLine = 4

    init(lines: [String], fontSize: CGFloat, wraps: Bool? = nil) throws {
        let body = lines.joined(separator: "\n")
        let document = DiffDocument(data: Data(
            "diff --git a/a.md b/a.md\n--- /dev/null\n+++ b/a.md\n@@ -0,0 +1,\(lines.count) @@\n\(body)\n".utf8
        ))
        let rows = wraps.map { DiffRows(document: document, threads: [], longLines: .init(wraps: $0)) }
            ?? DiffRows(document: document, threads: [])
        let font = DiffFont(face: .menlo, size: fontSize)
        container = DiffTableContainer(
            document: document, rows: rows, viewed: [], font: font, onContent: {}, actions: Self.actions
        )
        container.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        #if os(iOS)
            metrics = container.metrics
            container.layoutIfNeeded()
        #else
            metrics = container.metrics
            container.tile()
            container.layoutSubtreeIfNeeded()
        #endif
    }

    /// How far the code scrolls sideways.
    var sidewaysRoom: CGFloat {
        #if os(iOS)
            container.contentSize.width - container.bounds.width
        #else
            (container.table.tableColumns.first?.width ?? 0) - container.contentView.bounds.width
        #endif
    }

    /// The file's code row `index`, under its hunk's header, laid out at the height the table gives it.
    func row(_ code: Int) throws -> Row {
        let index = code + 1
        #if os(iOS)
            let path = IndexPath(row: index, section: 0)
            let height = container.tableView(container.table, heightForRowAt: path)
            let cell = try #require(container.tableView(container.table, cellForRowAt: path) as? DiffLineCell)
            cell.frame = CGRect(x: 0, y: 0, width: container.table.bounds.width, height: height)
            cell.layoutIfNeeded()
            let needed = cell.label.sizeThatFits(
                CGSize(width: cell.label.frame.width, height: .greatestFiniteMagnitude)
            )
            return Row(
                text: cell.label.text ?? "", height: height, labelFrame: cell.label.frame, neededHeight: needed.height,
                numberFrame: cell.newNumber.frame, numberIsAtTheTop: cell.newNumber.frame.minY == 0
            )
        #else
            // The header is the list's row 0.
            let height = container.tableView(container.table, heightOfRow: index + 1)
            let column = container.table.tableColumns.first
            let cell = try #require(container.tableView(container.table, viewFor: column, row: index + 1) as? DiffLineView)
            cell.frame = NSRect(x: 0, y: 0, width: column?.width ?? 0, height: height)
            cell.layoutSubtreeIfNeeded()
            let room = NSRect(x: 0, y: 0, width: cell.label.frame.width, height: 1_000_000)
            let needed = cell.label.cell?.cellSize(forBounds: room).height ?? 0
            return Row(
                text: cell.label.stringValue, height: height, labelFrame: cell.label.frame, neededHeight: needed,
                numberFrame: cell.newNumber.frame, numberIsAtTheTop: cell.newNumber.frame.maxY == cell.bounds.maxY
            )
        #endif
    }

    private static var actions: DiffActions {
        DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { _ in }, closeNote: {},
            isReviewed: { _ in false }, setReviewed: { _, _ in }, explain: nil, setBarsHidden: { _ in },
            setKeyboardUp: { _ in }, removeDraft: { _ in }, reply: { _, _ in }, setResolved: { _, _ in },
            showsFileOnTop: { _ in }
        )
    }
}
