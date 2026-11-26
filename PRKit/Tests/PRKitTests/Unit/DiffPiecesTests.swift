import Foundation
@testable import PRKit
import Testing

/// A very long line as pieces: together they are the line, each ends where a wrapped line would, none ends inside a
/// character, and only the first few are rows until the reader asks for the rest.
struct DiffPiecesTests {
    private static func document(_ line: String) -> DiffDocument {
        DiffDocument(data: Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+\(line)\n".utf8))
    }

    private static let addedLine = 5

    private func pieces(of document: DiffDocument) -> [String] {
        (0 ..< document.pieceCount(ofLine: Self.addedLine)).map { document.text(ofLine: Self.addedLine, piece: $0) }
    }

    @Test func aLineThatFitsAKilobyteIsOnePiece() {
        let document = Self.document(String(repeating: "x", count: DiffDocument.pieceBytes - 1))
        #expect(document.pieces.isEmpty)
        #expect(document.pieceCount(ofLine: Self.addedLine) == 1)
        #expect(document.text(ofLine: Self.addedLine, piece: 0) == document.text(of: document.lines[Self.addedLine]))
    }

    @Test func thePiecesTogetherAreTheLine() {
        let line = String(repeating: #"{"id":1,"type":"timeseries","title":"Checkout"},"#, count: 600)
        let document = Self.document(line)
        let pieces = pieces(of: document)
        #expect(pieces.count > 20)
        #expect(pieces.joined() == "+" + line)
        #expect(pieces.allSatisfy { $0.utf8.count <= DiffDocument.pieceBytes })
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(",") }, "minified JSON breaks after a comma")
    }

    @Test func prosePiecesEndAfterASpace() {
        let line = String(repeating: "A panel turns red when one request in a hundred fails. ", count: 80)
        let pieces = pieces(of: Self.document(line))
        #expect(pieces.count > 3)
        #expect(pieces.joined() == "+" + line)
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(" ") })
    }

    /// Thai has three bytes a character and no spaces: a piece ends between characters, so none is drawn broken.
    @Test func aPieceNeverEndsInsideACharacter() {
        let line = String(repeating: "แผงควบคุมการชำระเงิน", count: 200)
        let pieces = pieces(of: Self.document(line))
        #expect(pieces.count > 5)
        #expect(pieces.joined() == "+" + line)
        #expect(pieces.allSatisfy { !$0.unicodeScalars.contains("\u{FFFD}") })
    }

    /// A paragraph written as one line is read whole, with no button, up to four kilobytes; a minified line is cut
    /// past its first piece, and anything is past four kilobytes.
    @Test func proseIsShownWholeAndMinifiedCodeIsCut() {
        let sentence = "A panel turns red when one request in a hundred fails. "
        let paragraph = Self.document(String(repeating: sentence, count: 40))
        #expect(paragraph.lines[Self.addedLine].length > 2000)
        #expect(paragraph.pieceCount(ofLine: Self.addedLine) == 1, "one row, with no seam in it")
        #expect(!paragraph.opensCut(Self.addedLine))
        #expect(DiffRows(document: paragraph, threads: []).cut.isEmpty)

        let essay = Self.document(String(repeating: sentence, count: 90))
        #expect(essay.lines[Self.addedLine].length > DiffDocument.wholeBytes)
        #expect(essay.opensCut(Self.addedLine))

        let script = Self.document(String(repeating: "function r(t,e){return t.retries<e.max};", count: 40))
        #expect(script.lines[Self.addedLine].length < 2000)
        #expect(script.opensCut(Self.addedLine))

        let short = Self.document(String(repeating: "function r(t,e){return t.retries<e.max};", count: 20))
        #expect(!short.opensCut(Self.addedLine), "one piece: nothing to cut")
    }

    @Test func aVeryLongLineShowsItsStartThenTheRestWhenAsked() {
        let line = String(repeating: #"{"id":1,"type":"timeseries"},"#, count: 4000)
        let document = Self.document(line)
        let pieces = document.pieceCount(ofLine: Self.addedLine)
        #expect(pieces > 100)

        let cut = DiffRows(document: document, threads: [])
        // After them, the row for what the diff leaves out past its hunk (`DiffGapTests`).
        #expect(cut.files[0].rows.count == 5, "the hunk, the removed line, the line's start, Show full line")
        #expect(cut.files[0].rows.dropLast().last == .rest(Self.addedLine))
        #expect(cut.cut == [Self.addedLine])

        let id = DiffRows.LineID(document.lines[Self.addedLine], in: document)
        let whole = DiffRows(document: document, threads: [], longLines: .init(whole: [id])).files[0].rows
        #expect(whole.count == 4 + pieces, "every piece, then Show less")
        #expect(whole.dropLast().last == .less(Self.addedLine))

        let scrolled = DiffRows(document: document, threads: [], longLines: .init(wraps: false)).files[0].rows
        #expect(scrolled == [.line(3), .line(4), .line(5), .gap(0)], "one row a line where lines scroll sideways")
    }

    /// What a wrapped line's later rows are set in past: the code's own start.
    @Test func aLongLinesIndentCountsATabAsFourColumns() {
        let document = DiffDocument(data: Data(
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n+\t\tcurl\n+        let x\n-plain\n".utf8
        ))
        #expect(document.indentColumns(of: document.lines[4]) == 8)
        #expect(document.indentColumns(of: document.lines[5]) == 9)
        #expect(document.indentColumns(of: document.lines[6]) == 1)
        #expect(document.indentColumns(of: document.lines[3]) == 0, "a hunk's header has no indentation")
    }
}
