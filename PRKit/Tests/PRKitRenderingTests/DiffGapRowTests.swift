import Foundation
@testable import PRKit
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The rows of the lines a diff leaves out, in the phone's table and the Mac's: "Show N hidden lines" is a button a
/// test and VoiceOver find by its identifier, a press asks for its gap, a revealed line is drawn with its numbers in
/// both files, and a file's header carries "Show whole file".
@MainActor
struct DiffGapRowTests {
    /// Line 6 is new and line 13 replaces one: the diff leaves out lines 1 to 4, 9 to 12 and what follows line 14.
    private static let diff = """
    diff --git a/f.txt b/f.txt
    --- a/f.txt
    +++ b/f.txt
    @@ -5,3 +5,4 @@
     line 5
    +line 6
     line 7
     line 8
    @@ -12,2 +13,2 @@
    -old line
    +line 13
     line 14

    """

    private static let text = Data((1 ... 20).map { "line \($0)\n" }.joined().utf8)

    /// What the table asked for.
    final class Asked {
        var toggled: [DiffRows.Gap] = []
        var whole: [Bool] = []
        var composed: [Int?] = []
    }

    private static func table(
        hidden: DiffRows.Hidden = .init(), reads: Bool = false, asked: Asked = Asked()
    ) -> (DiffTableContainer, DiffRows, DiffDocument) {
        var document = DiffDocument(data: Data(diff.utf8))
        if reads {
            document = document.showing(text, forFile: 0)
        }
        let rows = DiffRows(document: document, threads: [], hidden: hidden)
        var actions = DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { asked.composed.append($0) },
            closeNote: {}, isReviewed: { _ in false }, setReviewed: { _, _ in }, explain: nil, setBarsHidden: { _ in },
            setKeyboardUp: { _ in }, pending: .none, reply: { _, _ in }, setResolved: { _, _ in },
            showsFileOnTop: { _ in }
        )
        actions.hidden.toggle = { asked.toggled.append($0) }
        actions.hidden.setWholeFile = { isOn, _ in asked.whole.append(isOn) }
        let container = DiffTableContainer(
            document: document, rows: rows, viewed: [], font: DiffFont(face: .menlo, size: 12), onContent: {},
            actions: actions
        )
        container.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        #if os(iOS)
            container.layoutIfNeeded()
        #else
            container.tile()
            container.layoutSubtreeIfNeeded()
        #endif
        return (container, rows, document)
    }

    /// The file's row `index` as the table draws it: its view, and what a test finds it by.
    private struct Drawn {
        let identifier: String?
        let title: String?
        let height: CGFloat
        let isButton: Bool
        let numbers: [String]
        let code: String?
    }

    private static func drawn(_ index: Int, in container: DiffTableContainer) throws -> Drawn {
        #if os(iOS)
            let path = IndexPath(row: index, section: 0)
            let cell = container.tableView(container.table, cellForRowAt: path)
            let line = cell as? DiffLineCell
            return Drawn(
                identifier: cell.accessibilityIdentifier, title: cell.accessibilityLabel,
                height: container.tableView(container.table, heightForRowAt: path),
                isButton: cell.isAccessibilityElement && cell.accessibilityTraits.contains(.button),
                numbers: [line?.oldNumber.text ?? "", line?.newNumber.text ?? ""],
                code: line?.label.attributedText?.string ?? line?.label.text
            )
        #else
            // The header is the list's row 0.
            let view = try #require(container.tableView(container.table, viewFor: container.table.tableColumns.first, row: index + 1))
            let line = view as? DiffLineView
            let button = view.subviews.compactMap { $0 as? NSButton }.first
            return Drawn(
                identifier: button?.accessibilityIdentifier() ?? view.accessibilityIdentifier(),
                title: button?.accessibilityLabel(), height: container.tableView(container.table, heightOfRow: index + 1),
                isButton: button?.isAccessibilityElement() == true && button?.accessibilityRole() == .button,
                numbers: [line?.oldNumber.stringValue ?? "", line?.newNumber.stringValue ?? ""],
                code: line?.label.stringValue
            )
        #endif
    }

    private static func press(_ index: Int, in container: DiffTableContainer) {
        #if os(iOS)
            container.tableView(container.table, didSelectRowAt: IndexPath(row: index, section: 0))
        #else
            container.clicked(index + 1)
        #endif
    }

    @Test func aGapsRowIsAButtonNamedForItsFileAndPlace() throws {
        let (container, rows, _) = Self.table()
        #expect(rows.files[0].rows.first == .gap(0) && rows.files[0].rows[6] == .gap(1))
        let before = try Self.drawn(0, in: container)
        #expect(before.identifier == "diff-gap-0-0" && before.title == "Show 4 hidden lines")
        #expect(before.isButton, "a test and VoiceOver find it as a button")
        #expect(before.height >= container.metrics.rowHeight)
        let between = try Self.drawn(6, in: container)
        #expect(between.identifier == "diff-gap-0-1" && between.title == "Show 4 hidden lines")
        let after = try Self.drawn(11, in: container)
        #expect(after.identifier == "diff-gap-0-2" && after.title == "Show hidden lines")
    }

    @Test func aPressOnAGapsRowAsksForItsGap() {
        let asked = Asked()
        let (container, rows, _) = Self.table(asked: asked)
        Self.press(6, in: container)
        #expect(asked.toggled.map(\.id) == [rows.gaps[1].id])
        #expect(asked.composed.isEmpty, "it is no line to comment on")
    }

    @Test func theRowReadsTheSameWhileItsFileIsRead() throws {
        let (container, _, _) = Self.table(hidden: .init(loading: ["f.txt"]))
        let row = try Self.drawn(6, in: container)
        #expect(row.identifier == "diff-gap-0-1" && row.title == "Show 4 hidden lines")
    }

    @Test func aRevealedLineIsDrawnWithItsNumbersInBothFiles() throws {
        let asked = Asked()
        let hidden = DiffRows.Hidden(gaps: [DiffRows.GapID(path: "f.txt", first: 9)])
        let (container, rows, document) = Self.table(hidden: hidden, reads: true, asked: asked)
        #expect(rows.files[0].rows[6] == .line(document.diffLineCount + 8))
        let line = try Self.drawn(6, in: container)
        #expect(line.identifier == "diff-hidden-line-0-9")
        #expect(line.numbers == ["8", "9"], "old line 8 is new line 9: one line was added above")
        #expect(line.code == " line 9")
        #expect(line.height == container.metrics.rowHeight, "a row of code like any other")
        let less = try Self.drawn(10, in: container)
        #expect(less.identifier == "diff-gap-less-0-1" && less.title == "Show less" && less.isButton)
        Self.press(10, in: container)
        #expect(asked.toggled.map(\.id.first) == [9])
        // A press on the line itself asks for its comment box, as on any line of code.
        Self.press(6, in: container)
        #expect(asked.composed == [document.diffLineCount + 8])
    }

    @Test func aFailedReadIsARowOfItsOwnAndAPressOnItAsksNothing() {
        let asked = Asked()
        var hidden = DiffRows.Hidden()
        hidden.failures["f.txt"] = .init(first: 9, words: "This file is too large to show.")
        let (container, rows, _) = Self.table(hidden: hidden, asked: asked)
        #expect(rows.gaps[1].state == .failed("This file is too large to show."))
        #if os(iOS)
            let cell = container.tableView(container.table, cellForRowAt: IndexPath(row: 6, section: 0))
            #expect(cell is DiffHostedCell, "the reason and Try again, drawn by SwiftUI")
        #else
            #expect(container.hostedID(section: 0, row: 6) == rows.gaps[1].failureID)
            #expect(container.hostedRow(section: 0, row: 6) != nil, "the reason and Try again, drawn by SwiftUI")
        #endif
        Self.press(6, in: container)
        #expect(asked.toggled.isEmpty, "its own button tries again")
    }

    @Test func aFilesHeaderOffersShowWholeFileTickedWhileItIsOn() throws {
        for isOn in [false, true] {
            let asked = Asked()
            let hidden = DiffRows.Hidden(files: isOn ? ["f.txt"] : [])
            let (container, rows, _) = Self.table(hidden: hidden, reads: true, asked: asked)
            #expect(rows.files[0].showsWhole == isOn)
            #if os(iOS)
                let header = try #require(container.tableView(container.table, viewForHeaderInSection: 0) as? DiffFileHeader)
                let menu = header.contextMenuInteraction(
                    UIContextMenuInteraction(delegate: header), configurationForMenuAtLocation: .zero
                )
                #expect(menu != nil, "a long press opens its menu")
                header.onWhole(!isOn)
            #else
                let header = try #require(container.headerView(0) as? DiffFileHeaderView)
                let item = try #require(header.menu?.items.first)
                #expect(item.title == "Show whole file", "the same words on and off")
                #expect(item.state == (isOn ? .on : .off))
                #expect(item.accessibilityIdentifier() == "diff-whole-file-f.txt")
                let target = try #require(item.target as? NSObject)
                _ = try target.perform(#require(item.action))
            #endif
            #expect(asked.whole == [!isOn])
        }
    }

    @Test func aFileWithNothingLeftOutHasNoMenu() {
        let document = DiffDocument(data: Data("diff --git a/n b/n\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+one\n".utf8))
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.files[0].showsWhole == nil)
        #if os(macOS)
            let header = DiffFileHeaderView(
                rows.files[0], section: 0, isCollapsed: false, isViewed: false, metrics: DiffMetrics(DiffFont(face: .menlo, size: 12))
            )
            #expect(header.menu == nil)
        #endif
    }
}

/// A gap whose file's text could not be read, as its row is drawn in the phone's table and the Mac's
/// (`DiffGapFailure`): why, in the bad tone, over a "Try again" button. That a failed read is this row is
/// `DiffGapRowTests`'; what a failure's words are and that a second read clears it are `PRHiddenLinesTests`'.
@MainActor
struct DiffGapFailureTests {
    private static let width: CGFloat = 370
    private static let scale: CGFloat = 2
    private static let words = "This file is too large to show."

    /// `src/checkout/rates.json`'s first gap in the sample acme/web#431, its third file.
    private static func gap(saying words: String) -> DiffRows.Gap {
        DiffRows.Gap(
            file: 2, ordinal: 0, id: DiffRows.GapID(path: "src/checkout/rates.json", first: 1), last: 4,
            state: .failed(words)
        )
    }

    private func render(_ view: some View, width: CGFloat? = Self.width, in scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view.frame(width: width).tint(Color.accentColor).environment(\.colorScheme, scheme)
        )
        renderer.scale = Self.scale
        return try renderer.settledImage()
    }

    private func row(_ words: String, in scheme: ColorScheme) throws -> CGImage {
        try render(DiffGapFailure(gap: Self.gap(saying: words), words: words) {}, in: scheme)
    }

    /// Whether `part` is drawn in `whole` with its top left corner at `column`, `row`.
    private func isDrawn(_ part: Bitmap, in whole: Bitmap, column: Int, row: Int) -> Bool {
        guard column >= 0, row >= 0, column + part.width <= whole.width, row + part.height <= whole.height else {
            return false
        }
        for down in 0 ..< part.height {
            for across in 0 ..< part.width where !part[across, down].isNear(whole[column + across, row + down]) {
                return false
            }
        }
        return true
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theRowIsWhyOverATryAgainButton(_ scheme: ColorScheme) throws {
        let gap = Self.gap(saying: Self.words)
        #expect(DiffRows.Gap.retryTitle == "Try again")
        #expect(gap.identifier("retry") == "diff-gap-retry-2-0" && gap.identifier() == "diff-gap-2-0")

        let image = try row(Self.words, in: scheme)
        try Attachment.record(image.png(), named: "diff-gap-failed-\(scheme).png")
        let drawn = try Bitmap(image)

        // The button as any secondary button with these words is drawn, on the card's ground: found whole in the
        // row, at the card's leading inset and over its foot's.
        let button = try Bitmap(render(
            Button("Try again") {}.buttonStyle(PRButtonStyle(.secondary)).background(Color.groundCard), width: nil,
            in: scheme
        ))
        let inset = Int(PRStyle.inset * Self.scale)
        let top = drawn.height - inset - button.height
        let found = (-2 ... 2).contains { isDrawn(button, in: drawn, column: inset, row: top + $0) }
        #expect(found, "a Try again button \(button.width) by \(button.height) px, \(inset) px in and up from the foot")

        // Its words take their room over the button: said in more lines, the row is taller.
        let long = try Bitmap(row(Array(repeating: Self.words, count: 6).joined(separator: " "), in: scheme))
        #expect(long.height > drawn.height, "\(long.height) px for six times the words, \(drawn.height) px for them once")
        #if os(iOS)
            // In the app's own test host, where the tones are its colour sets: the words are in the bad tone.
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let red = Pixel(Color.toneBad.resolve(in: environment))
            let rows = (0 ..< drawn.height).filter { row in
                (0 ..< drawn.width).contains { drawn[$0, row].distance(to: red) <= 60 }
            }
            #expect(rows.count >= Int(4 * Self.scale), "why, in the bad tone: \(rows.count) rows of it")
            #expect((rows.max() ?? drawn.height) < top, "over the button")
        #endif
    }
}
