import Foundation
@testable import PRKit
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The sample PR of long lines (`LongLineSample`), each read to its last characters in the real table on a phone's
/// width: what the UI tests read by scrolling a running app to each line's end, in the light, in the dark and in the
/// largest text (a teammate's feedback, 2026-11-25: each line was cut at 160 columns with no way to the rest). A short
/// paragraph, a call and minified JSON under a kilobyte are `DiffLongLineTests`'.
@MainActor
struct DiffLongLineSampleTests {
    /// The row is the whole of `line`, to `tail`, wrapped inside the table's width with every wrapped row in it.
    private static func expectWhole(_ row: LongLineTable.Row, tail: String, in table: LongLineTable) {
        #expect(LongLineTable.ends(row.text, in: tail), "\(tail): the row's text reaches the line's last characters")
        #expect(!row.text.hasSuffix("⋯"), "\(tail): no cut mark")
        #expect(row.labelFrame.minX >= 0 && row.labelFrame.maxX <= table.width, "\(tail): inside the screen's sides")
        #expect(row.neededHeight <= row.labelFrame.height + 0.5, "\(tail): every wrapped row of it is inside its row")
        #expect(row.neededHeight > table.metrics.rowHeight * 2, "\(tail): the case this is for, it takes several rows")
    }

    /// A paragraph of 1,900 characters, the paragraph it replaced, a comment, a string and a tab-indented command: each
    /// is one row with no button, whole.
    @Test(
        arguments: ["END-OF-LONG-PARAGRAPH", "END-OF-OLD-PARAGRAPH", "END-OF-COMMENT", "END-OF-STRING", "END-OF-TABS"],
        [CGFloat(12), 20]
    )
    func aLongLineOfTheSampleIsDrawnToItsLastCharacters(tail: String, size: CGFloat) throws {
        let table = try LongLineTable(diff: LongLineSample.diff, fontSize: size)
        let found = table.lines(endingIn: tail)
        let index = try #require(found.first, "\(tail) ends a line of the sample")
        #expect(found.count == 1)
        #expect(table.kinds(ofLine: index) == ["line"], "one row, with no Show full line under it")
        let row = try #require(table.rows(ofLine: index).first)
        #expect(row.text == table.document.text(of: table.document.lines[index]), "the whole line")
        Self.expectWhole(row, tail: tail, in: table)
        #expect(table.sidewaysRoom <= 0.5, "nothing to scroll sideways")
    }

    /// A dashboard saved as one line of 5 KB, the old line and the new, and a minified script of 12 KB: each opens as
    /// its start over "Show full line"; shown whole it is a row a piece, the pieces together the line, the last one
    /// drawn to the line's last characters with "Show less" under it.
    @Test(arguments: ["END-OF-JSON", "END_OF_SCRIPT()"])
    func aMinifiedLineShownWholeIsDrawnToItsLastCharacters(tail: String) throws {
        let cut = try LongLineTable(diff: LongLineSample.diff)
        let whole = try LongLineTable(diff: LongLineSample.diff, showsWhole: true)
        let found = cut.lines(endingIn: tail)
        #expect(found.count == (tail == "END-OF-JSON" ? 2 : 1), "the dashboard's line is there twice, old and new")
        for index in found {
            #expect(cut.kinds(ofLine: index) == ["line", "rest"], "it opens as its start, over Show full line")
            let start = try #require(cut.rows(ofLine: index).first)
            #expect(!start.text.contains(tail), "the start alone")

            let pieces = cut.document.pieceCount(ofLine: index)
            #expect(pieces > 3)
            #expect(whole.kinds(ofLine: index) == ["line"] + [String](repeating: "piece", count: pieces - 1) + ["less"])
            let rows = try whole.rows(ofLine: index)
            #expect(rows.map(\.text).joined() == whole.document.text(of: whole.document.lines[index]), "the whole line")
            for (piece, row) in rows.enumerated() {
                #expect(row.labelFrame.minX >= 0 && row.labelFrame.maxX <= whole.width, "piece \(piece) is inside the sides")
                #expect(row.neededHeight <= row.labelFrame.height + 0.5, "piece \(piece): every wrapped row is in its row")
                #expect(row.numbers.isEmpty == (piece > 0), "the line's number is beside its first piece alone")
            }
            let last = try #require(rows.last)
            #expect(LongLineTable.ends(last.text, in: tail), "the last piece reaches the line's last characters")
        }
        #expect(whole.sidewaysRoom <= 0.5, "nothing to scroll sideways")
    }

    /// The largest text leaves a row a dozen characters: a line is still read to its end, and its later rows are set
    /// in by no more than a quarter of the room, however far the line itself is indented. This is that room, made by a
    /// narrow table, so the Mac's table is checked too; the phone's own largest text is the test under this one.
    @Test(arguments: ["END-OF-SHORT-PARAGRAPH", "END-OF-COMMENT", "END-OF-TABS"])
    func inARoomOfADozenCharactersALineIsDrawnToItsLastCharacters(tail: String) throws {
        let table = try LongLineTable(diff: LongLineSample.diff, fontSize: 20, width: 230)
        try Self.expectReadInANarrowRoom(tail, in: table)
    }

    #if os(iOS)
        /// The same in the phone's largest text size itself, AX5.
        @Test(arguments: ["END-OF-SHORT-PARAGRAPH", "END-OF-COMMENT", "END-OF-TABS"])
        func inTheLargestTextALineIsDrawnToItsLastCharacters(tail: String) throws {
            let table = try LongLineTable(diff: LongLineSample.diff, largestText: true)
            #expect(table.metrics.code.pointSize > 30, "the code is drawn in the largest text: \(table.metrics.code.pointSize) pt")
            try Self.expectReadInANarrowRoom(tail, in: table)
        }
    #endif

    private static func expectReadInANarrowRoom(_ tail: String, in table: LongLineTable) throws {
        let wrap = try #require(table.container.wrap)
        #expect((6 ... 16).contains(wrap.columns), "a row holds about a dozen characters: \(wrap.columns)")
        let index = try #require(table.lines(endingIn: tail).first)
        let row = try #require(table.rows(ofLine: index).first)
        #expect(row.text == table.document.text(of: table.document.lines[index]), "the whole line")
        expectWhole(row, tail: tail, in: table)
        #expect(table.sidewaysRoom <= 0.5, "nothing to scroll sideways")
        let text = wrap.text(line: index, piece: 0, of: table.document)
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent <= wrap.width / 4, "the later rows are set in \(style.headIndent) pt of \(wrap.width)")
    }

    // MARK: - Light and dark

    /// A wrapped line's ink follows the appearance: an added paragraph, the removed one and a comment are each read on
    /// their row's ground, in the light and in the dark. Wrapped text carries its own colour, which a label's does not
    /// reach.
    @Test(arguments: ["END-OF-SHORT-PARAGRAPH", "END-OF-OLD-PARAGRAPH", "END-OF-COMMENT"], [false, true])
    func aWrappedLineIsReadOnItsRowsGround(tail: String, isDark: Bool) throws {
        let table = try LongLineTable(diff: LongLineSample.diff)
        let index = try #require(table.lines(endingIn: tail).first)
        let row = try #require(table.rows(ofLine: index).first)
        let ink = try Self.ink(of: row, isDark: isDark)
        let page = Self.resolved(Self.pageGround, isDark: isDark)
        let ground = Self.resolved(DiffStyle.background(table.document.lines[index].kind), isDark: isDark).over(page)
        let contrast = ink.pixel.contrast(with: ground.pixel)
        #expect(contrast >= 4.5, "\(tail), \(isDark ? "dark" : "light"): \(ink.pixel) on \(ground.pixel) is \(contrast) to 1")
    }

    /// One colour, sRGB.
    private struct Ink {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        var pixel: Pixel {
            let byte = { (part: Double) in Int((min(max(part, 0), 1) * 255).rounded()) }
            return Pixel(red: byte(red), green: byte(green), blue: byte(blue))
        }

        /// This colour laid over an opaque `ground`.
        func over(_ ground: Ink) -> Ink {
            Ink(
                red: red * alpha + ground.red * (1 - alpha), green: green * alpha + ground.green * (1 - alpha),
                blue: blue * alpha + ground.blue * (1 - alpha), alpha: 1
            )
        }
    }

    /// What is under the diff's rows.
    private static var pageGround: PlatformColor {
        #if os(iOS)
            .systemBackground
        #else
            .windowBackgroundColor
        #endif
    }

    private static func resolved(_ color: PlatformColor, isDark: Bool) -> Ink {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(iOS)
            _ = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
            NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                color.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            }
        #endif
        return Ink(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    #if os(iOS)
        /// The colour the row's label draws its last characters in: the text's own, or the label's where it has none.
        private static func ink(of row: LongLineTable.Row, isDark: Bool) throws -> Ink {
            let label = try #require((row.view as? DiffLineCell)?.label)
            let text = try #require(label.attributedText)
            try #require(text.length > 0)
            let own = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? UIColor
            let page = resolved(pageGround, isDark: isDark)
            return try resolved(#require(own ?? label.textColor), isDark: isDark).over(page)
        }
    #else
        /// The colour the row's text is drawn in: the row's view drawn alone in the appearance, and the ink read from
        /// the middles of its strokes.
        private static func ink(of row: LongLineTable.Row, isDark: Bool) throws -> Ink {
            let view = row.view
            view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            let label = try #require((view as? DiffLineView)?.label)
            let drawn = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: drawn)
            let bitmap = try Bitmap(#require(drawn.cgImage))
            let scale = Double(bitmap.width) / Double(view.bounds.width)
            var sum = Ink(red: 0, green: 0, blue: 0, alpha: 0)
            var count = 0.0
            // The code's column alone: the numbers beside it are a quieter colour.
            for column in Int(Double(label.frame.minX) * scale) ..< bitmap.width {
                for line in 0 ..< bitmap.height {
                    let offset = (line * bitmap.width + column) * 4
                    let alpha = Double(bitmap.bytes[offset + 3])
                    // A stroke's middle is all ink; its edges are part ground.
                    guard alpha >= 200 else {
                        continue
                    }
                    sum.red += Double(bitmap.bytes[offset]) / alpha
                    sum.green += Double(bitmap.bytes[offset + 1]) / alpha
                    sum.blue += Double(bitmap.bytes[offset + 2]) / alpha
                    sum.alpha += alpha / 255
                    count += 1
                }
            }
            try #require(count > 100, "the row's text was drawn: \(count) pixels of ink")
            let ink = Ink(red: sum.red / count, green: sum.green / count, blue: sum.blue / count, alpha: sum.alpha / count)
            return ink.over(resolved(pageGround, isDark: isDark))
        }
    #endif
}
