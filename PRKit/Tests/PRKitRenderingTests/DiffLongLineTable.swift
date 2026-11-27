import Foundation
@testable import PRKit
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A diff in the real table, laid out on a phone's width: what `DiffLongLineTests` and `DiffLongLineSampleTests` read
/// their rows from. The Mac's table is laid out the same way.
@MainActor
struct LongLineTable {
    /// A row of code as the table draws it, at the height the table gives it.
    struct Row {
        let text: String
        let height: CGFloat
        let labelFrame: CGRect
        /// What the label's text needs at the label's width.
        let neededHeight: CGFloat
        let numberFrame: CGRect
        let numberIsAtTheTop: Bool
        /// The line's numbers beside the row, the old then the new: empty beside a later piece of a line.
        let numbers: String
        /// The row's own view, for a test that draws it.
        let view: PlatformView
    }

    #if os(iOS)
        typealias PlatformView = UIView
        /// The text size the phone calls the largest, AX5.
        static let largestText = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    #else
        typealias PlatformView = NSView
    #endif

    static let phoneWidth: CGFloat = 402

    let container: DiffTableContainer
    let metrics: DiffMetrics
    let width: CGFloat
    /// The document's index of the first file's first code line.
    let firstLine = 4

    var document: DiffDocument {
        container.document
    }

    /// One new file of `lines`, each an added line with its `+`.
    init(lines: [String], fontSize: CGFloat, wraps: Bool? = nil) throws {
        let body = lines.joined(separator: "\n")
        try self.init(
            diff: "diff --git a/a.md b/a.md\n--- /dev/null\n+++ b/a.md\n@@ -0,0 +1,\(lines.count) @@\n\(body)\n",
            fontSize: fontSize, wraps: wraps
        )
    }

    /// `showsWhole` opens every line that opens cut, as a tap on each "Show full line" does. `largestText` lays the
    /// table out in the phone's largest text size; the Mac has no such size, so there it changes nothing.
    init(
        diff: String, fontSize: CGFloat = 12, width: CGFloat = phoneWidth, wraps: Bool? = nil, showsWhole: Bool = false,
        largestText: Bool = false
    ) throws {
        let document = DiffDocument(data: Data(diff.utf8))
        var longLines = DiffRows.LongLines()
        if showsWhole {
            longLines.whole = Set(
                document.lines.indices.filter(document.opensCut).map { DiffRows.LineID(document.lines[$0], in: document) }
            )
        }
        if let wraps {
            longLines.wraps = wraps
        }
        // With nothing asked for, the rows are built as the screen builds them by default.
        let rows = wraps == nil && !showsWhole
            ? DiffRows(document: document, threads: []) : DiffRows(document: document, threads: [], longLines: longLines)
        let font = DiffFont(face: .menlo, size: fontSize)
        let make = {
            DiffTableContainer(document: document, rows: rows, viewed: [], font: font, onContent: {}, actions: Self.actions)
        }
        #if os(iOS)
            if largestText {
                // The table takes its text size from the traits it is made in.
                var made: DiffTableContainer?
                Self.largestText.performAsCurrent { made = make() }
                container = try #require(made)
            } else {
                container = make()
            }
        #else
            container = make()
        #endif
        self.width = width
        container.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        metrics = container.metrics
        #if os(iOS)
            container.layoutIfNeeded()
        #else
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

    /// The first file's code row `code`, under its hunk's header.
    func row(_ code: Int) throws -> Row {
        try row(code + 1, ofFile: 0)
    }

    /// The document's lines whose text ends in `tail`, but for a quote or a bracket closing after it.
    func lines(endingIn tail: String) -> [Int] {
        document.lines.indices.filter { index in
            let line = document.lines[index]
            // A line too short to hold the tail is not read: most of a diff's lines.
            guard line.length >= tail.utf8.count, line.kind != .file, line.kind != .meta else {
                return false
            }
            return Self.ends(document.text(of: line), in: tail)
        }
    }

    static func ends(_ text: String, in tail: String) -> Bool {
        text.suffix(tail.count + 2).contains(tail)
    }

    /// What the table has for the document's line `index`, in order: its rows of code, then "rest" under a line shown
    /// cut or "less" under one shown whole.
    func kinds(ofLine index: Int) -> [String] {
        let file = document.lines[index].file
        return container.rows.files[file].rows.compactMap { row in
            switch row {
            case .line(index): "line"
            case .piece(index, _): "piece"
            case .rest(index): "rest"
            case .less(index): "less"
            default: nil
            }
        }
    }

    /// The rows of code the table draws for the document's line `index`: one, or a piece each where the line is long
    /// and shown whole.
    func rows(ofLine index: Int) throws -> [Row] {
        let file = document.lines[index].file
        return try container.rows.files[file].rows.enumerated().compactMap { place, row in
            switch row {
            case .line(index), .piece(index, _): try self.row(place, ofFile: file)
            default: nil
            }
        }
    }

    /// The file's row `index`, a row of code, laid out at the height the table gives it.
    func row(_ index: Int, ofFile file: Int) throws -> Row {
        #if os(iOS)
            let path = IndexPath(row: index, section: file)
            let height = container.tableView(container.table, heightForRowAt: path)
            let cell = try #require(container.tableView(container.table, cellForRowAt: path) as? DiffLineCell)
            cell.frame = CGRect(x: 0, y: 0, width: container.table.bounds.width, height: height)
            cell.layoutIfNeeded()
            let needed = cell.label.sizeThatFits(
                CGSize(width: cell.label.frame.width, height: .greatestFiniteMagnitude)
            )
            return Row(
                text: cell.label.text ?? "", height: height, labelFrame: cell.label.frame, neededHeight: needed.height,
                numberFrame: cell.newNumber.frame, numberIsAtTheTop: cell.newNumber.frame.minY == 0,
                numbers: (cell.oldNumber.text ?? "") + (cell.newNumber.text ?? ""), view: cell
            )
        #else
            // Each file's header is a row of the list too.
            let item = try #require(container.items.firstIndex(of: .row(section: file, row: index)))
            let height = container.tableView(container.table, heightOfRow: item)
            let column = container.table.tableColumns.first
            let cell = try #require(container.tableView(container.table, viewFor: column, row: item) as? DiffLineView)
            cell.frame = NSRect(x: 0, y: 0, width: column?.width ?? 0, height: height)
            cell.layoutSubtreeIfNeeded()
            let room = NSRect(x: 0, y: 0, width: cell.label.frame.width, height: 1_000_000)
            let needed = cell.label.cell?.cellSize(forBounds: room).height ?? 0
            return Row(
                text: cell.label.stringValue, height: height, labelFrame: cell.label.frame, neededHeight: needed,
                numberFrame: cell.newNumber.frame, numberIsAtTheTop: cell.newNumber.frame.maxY == cell.bounds.maxY,
                numbers: cell.oldNumber.stringValue + cell.newNumber.stringValue, view: cell
            )
        #endif
    }

    private static var actions: DiffActions {
        DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { _ in }, closeNote: {},
            isReviewed: { _ in false }, setReviewed: { _, _ in }, explain: nil, setBarsHidden: { _ in },
            setKeyboardUp: { _ in }, pending: .none, reply: { _, _ in }, setResolved: { _, _ in },
            showsFileOnTop: { _ in }
        )
    }
}
