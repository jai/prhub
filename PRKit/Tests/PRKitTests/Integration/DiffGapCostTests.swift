import Foundation
@testable import PRKit
import Testing

/// What the lines a diff leaves out cost. Opening a diff is a pass over its bytes and a pass over its lines, and stays
/// so: the gaps come from the hunks the first pass already read. Showing a file's hidden lines reads that file's text
/// and nothing of the diff. Timed against the parse of the same bytes, on the same machine in the same run, so a slow
/// host moves both.
struct DiffGapCostTests {
    /// A hundred files of ten hunks each, 24,000 lines: 1,100 gaps.
    private static func bigDiff() -> Data {
        var text = ""
        for file in 0 ..< 100 {
            text += "diff --git a/src/file\(file).swift b/src/file\(file).swift\n--- a/src/file\(file).swift\n"
                + "+++ b/src/file\(file).swift\n"
            for hunk in 0 ..< 10 {
                let start = 10 + hunk * 50
                text += "@@ -\(start),18 +\(start),19 @@ func f()\n"
                for line in 0 ..< 19 {
                    text += line % 5 == 2
                        ? "-    let old = value(\(line))\n+    let new = value(\(line))\n" : "     keep(line: \(line), of: \(hunk))\n"
                }
            }
        }
        return Data(text.utf8)
    }

    private static func median(of runs: Int = 9, _ work: () -> Void) -> Duration {
        let times = (0 ..< runs).map { _ in ContinuousClock().measure(work) }
        return times.sorted()[runs / 2]
    }

    /// The rows of a diff are built in one pass over its lines, and the gaps come from the hunks the parse already
    /// read: finding 1,100 of them must not cost the open a second pass. The yardstick is the parse itself, which the
    /// same bytes always cost: before gaps existed the rows took three quarters of it (18 ms to 24 ms, a Debug build).
    @Test func findingTheGapsCostsOpeningADiffNoPassOfItsOwn() {
        let data = Self.bigDiff()
        let document = DiffDocument(data: data)
        #expect(document.diffLineCount > 20000 && document.hunks.count == 1000)
        #expect(DiffRows(document: document, threads: []).gaps.count == 1100)
        let parse = Self.median { _ = DiffDocument(data: data) }
        let rows = Self.median { _ = DiffRows(document: document, threads: []) }
        #expect(rows < parse * 1.5, "rows \(rows), parse \(parse)")
    }

    /// Showing a file's hidden lines reads that file's text and no more: the diff's 24,000 lines are not read again,
    /// and the rows cost what they did plus the lines shown.
    @Test func openingAGapCostsItsOwnLinesNotTheDiffs() {
        let data = Self.bigDiff()
        let document = DiffDocument(data: data)
        let text = Data((1 ... 600).map { "    keep(line: \($0))\n" }.joined().utf8)
        let parse = Self.median { _ = DiffDocument(data: data) }
        let reveal = Self.median { _ = document.showing(text, forFile: 50) }
        #expect(reveal < parse * 0.5, "reveal \(reveal), parse \(parse)")

        let whole = document.showing(text, forFile: 50)
        let hidden = DiffRows.Hidden(files: ["src/file50.swift"])
        #expect(DiffRows(document: whole, threads: [], hidden: hidden).files[50].rows.count > 600)
        let closed = Self.median { _ = DiffRows(document: document, threads: []) }
        let open = Self.median { _ = DiffRows(document: whole, threads: [], hidden: hidden) }
        #expect(open < closed * 2 + parse * 0.25, "open \(open), closed \(closed)")
    }
}
