import Foundation
@testable import PRKit
import Testing

/// The lines a diff leaves out: where they lie, read from the hunks' own headers; what they are numbered once the
/// file's text is here; and which of them are rows.
struct DiffGapTests {
    /// A file of twenty lines, "line 1" to "line 20", as the PR's head has it.
    private static func head(_ count: Int = 20, ending: String = "\n") -> Data {
        Data((1 ... count).map { "line \($0)" }.joined(separator: "\n").appending(ending).utf8)
    }

    /// Two hunks of that file: line 6 is new, and line 13 replaces one. The diff leaves out lines 1 to 4, 9 to 12 and
    /// 15 to 20. The old file is a line shorter from line 6 on.
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

    private static var document: DiffDocument {
        DiffDocument(data: Data(diff.utf8))
    }

    /// The document's index of line `number` of the file's own text, read after a diff of twelve lines.
    private static func fileLine(_ number: Int) -> Int {
        11 + number
    }

    private static func thread(path: String = "f.txt", line: Int, side: String = "RIGHT") throws -> PullRequestDetail.Thread {
        try JSONDecoder().decode(PullRequestDetail.Thread.self, from: Data("""
        {"id":"t\(line)","isResolved":false,"path":"\(path)","line":\(line),"diffSide":"\(side)","comments":{"nodes":[]}}
        """.utf8))
    }

    // MARK: - Where the gaps are

    @Test func theHunksSayWhatIsLeftOutBeforeBetweenAndAfterThem() {
        let document = Self.document
        #expect(document.hunks.map(\.newStart) == [5, 13] && document.hunks.map(\.oldStart) == [5, 12])
        #expect(document.hunks.map(\.newCount) == [4, 2] && document.hunks.map(\.oldCount) == [3, 2])
        #expect(document.shapes[0].hunks == 0 ..< 2)
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.files[0].rows == [
            .gap(0), .line(3), .line(4), .line(5), .line(6), .line(7),
            .gap(1), .line(8), .line(9), .line(10), .line(11), .gap(2),
        ])
        #expect(rows.gaps.map(\.id.first) == [1, 9, 15])
        #expect(rows.gaps.map(\.last) == [4, 12, nil], "only the file's text says where it ends")
        #expect(rows.gaps.map(\.title) == ["Show 4 hidden lines", "Show 4 hidden lines", "Show hidden lines"])
        #expect(rows.gaps.map { $0.identifier() } == ["diff-gap-0-0", "diff-gap-0-1", "diff-gap-0-2"])
        #expect(rows.gaps[1].identifier("less") == "diff-gap-less-0-1")
        #expect(rows.gaps.allSatisfy { $0.state == .closed })
        #expect(rows.files[0].showsWhole == false, "Show whole file, off")
    }

    @Test func aFileThatStartsAtItsFirstLineHasNothingBeforeIt() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n".utf8))
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.files[0].rows == [.line(3), .line(4), .line(5), .line(6), .gap(0)])
        #expect(rows.gaps.map(\.id.first) == [3])
    }

    @Test func aGapOfOneLineSaysOneLine() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2 +2 @@\n-a\n+b\n".utf8))
        #expect(DiffRows(document: document, threads: []).gaps.first?.title == "Show 1 hidden line")
    }

    /// `@@ -5 +5 @@`: a count left out is one line.
    @Test func aHunkOfOneLineIsCountedAsOne() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -5 +5 @@\n-old\n+new\n".utf8))
        #expect(document.hunks == [DiffDocument.Hunk(file: 0, oldStart: 5, oldCount: 1, newStart: 5, newCount: 1)])
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.gaps.map(\.id.first) == [1, 6] && rows.gaps.map(\.last) == [4, nil])
        let whole = document.showing(Self.head(8), forFile: 0)
        let open = DiffRows(document: whole, threads: [], hidden: .init(files: ["f"]))
        let shown = open.files[0].rows.compactMap(\.codeLine).map { whole.lines[$0] }.filter(\.isOutsideDiff)
        #expect(shown.map(\.newLine) == [1, 2, 3, 4, 6, 7, 8])
        #expect(shown.map(\.oldLine) == [1, 2, 3, 4, 6, 7, 8])
    }

    @Test func aNewADeletedAndABinaryFileLeaveNothingOut() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/logo.png b/logo.png
        index 1a2b3c4..5d6e7f8 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let document = DiffDocument(data: Data(text.utf8))
        #expect(document.shapes.map(\.isNew) == [true, false, false])
        #expect(document.shapes.map(\.isDeleted) == [false, true, false])
        #expect(document.shapes.map(\.isBinary) == [false, false, true])
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.gaps.isEmpty)
        #expect(rows.files.map(\.showsWhole) == [nil, nil, nil], "no Show whole file: the diff is all there is")
        #expect(rows.files[0].rows == [.line(4), .line(5), .line(6)])
        #expect(rows.files[2].rows == [.line(15), .line(16)], "a binary file keeps its header's lines")
    }

    @Test func aRenamedFileWithNoHunkOffersItsWholeText() {
        let text = "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n"
        let document = DiffDocument(data: Data(text.utf8))
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.files[0].rows == [.line(1), .line(2), .line(3), .gap(0)])
        #expect(rows.gaps[0].id == DiffRows.GapID(path: "new.txt", first: 1) && rows.gaps[0].last == nil)
        #expect(rows.files[0].showsWhole == false)

        let whole = document.showing(Self.head(3), forFile: 0)
        let open = DiffRows(document: whole, threads: [], hidden: .init(files: ["new.txt"]))
        #expect(open.files[0].rows == [.line(1), .line(2), .line(3), .line(4), .line(5), .line(6)])
        #expect(open.files[0].showsWhole == true)
        #expect((4 ... 6).map { whole.text(of: whole.lines[$0]) } == [" line 1", " line 2", " line 3"])
        #expect((4 ... 6).map { whole.lines[$0].oldLine } == [1, 2, 3], "nothing changed: the old numbers are the new")
    }

    /// `\ No newline at end of file` is said of a file's last line, so the hunk it is in reaches the file's end.
    @Test func aHunkThatReachesTheFilesEndHasNothingAfterIt() {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3,2 +3,2 @@\n a\n-b\n+c\n\\ No newline at end of file\n"
        let document = DiffDocument(data: Data(text.utf8))
        #expect(document.hunks[0].reachesEnd)
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.files[0].rows == [.gap(0), .line(3), .line(4), .line(5), .line(6), .line(7)])
    }

    // MARK: - The file's text

    @Test func aTextEndsWithOrWithoutANewlineAndCountsTheSameLines() {
        let ended = Self.document.showing(Self.head(), forFile: 0)
        let open = Self.document.showing(Self.head(ending: ""), forFile: 0)
        #expect(ended.texts[0]?.count == 20 && open.texts[0]?.count == 20)
        #expect(open.text(of: open.lines[Self.fileLine(20)]) == " line 20")
        #expect(Self.document.showing(Data(), forFile: 0).texts[0]?.count == 0)
    }

    @Test func aTextWithWindowsLineEndsLeavesTheReturnOut() {
        let text = Data((1 ... 20).map { "line \($0)\r\n" }.joined().utf8)
        let document = Self.document.showing(text, forFile: 0)
        #expect(document.texts[0]?.count == 20)
        #expect(document.text(of: document.lines[Self.fileLine(1)]) == " line 1")
        #expect(document.text(of: document.lines[Self.fileLine(20)]) == " line 20")
        #expect(!document.text(of: document.lines[Self.fileLine(9)]).contains("\r"))
    }

    @Test func theTextIsReadBesideTheDiffAndTheDiffIsNotReadAgain() {
        let document = Self.document
        let whole = document.showing(Self.head(), forFile: 0)
        #expect(whole.diffLineCount == document.diffLineCount && whole.lines.count == document.lines.count + 20)
        #expect(Array(whole.lines.prefix(document.lines.count)) == document.lines)
        #expect(whole.data == document.data && whole.hunks == document.hunks)
        #expect(whole.lines.dropFirst(document.lines.count).allSatisfy { $0.isOutsideDiff && $0.kind == .context })
        // Asked again, or of a file the diff does not have: the same document.
        #expect(whole.showing(Self.head(3), forFile: 0).lines.count == whole.lines.count)
        #expect(document.showing(Self.head(), forFile: 4).lines.count == document.lines.count)
        #expect(document.showing(["f.txt": Self.head(), "other": Self.head()]).lines.count == whole.lines.count)
    }

    /// An unchanged line is the same line in both files: its old number is its new one less what the hunks before it
    /// added.
    @Test func aRevealedLineIsNumberedInTheNewFileAndTheOld() {
        let document = Self.document.showing(Self.head(), forFile: 0)
        let numbers = { (new: Int) in
            let line = document.lines[Self.fileLine(new)]
            return [line.oldLine, line.newLine]
        }
        #expect(numbers(1) == [1, 1] && numbers(4) == [4, 4], "before the first hunk")
        #expect(numbers(9) == [8, 9] && numbers(12) == [11, 12], "between the hunks: one line was added above")
        #expect(numbers(15) == [14, 15] && numbers(20) == [19, 20], "after the last hunk")
        #expect(numbers(6) == [0, 6], "a line the diff itself shows is never a row from the text")
        #expect(document.lineNumberDigits == 3)
        let long = Self.document.showing(Self.head(1200), forFile: 0)
        #expect(long.lineNumberDigits == 4, "room for the file's largest number")
    }

    // MARK: - Rows

    @Test func anOpenedGapIsItsLinesThenShowLessAndClosesAgain() {
        let document = Self.document.showing(Self.head(), forFile: 0)
        let between = DiffRows.GapID(path: "f.txt", first: 9)
        let open = DiffRows(document: document, threads: [], hidden: .init(gaps: [between]))
        let lines = (9 ... 12).map { DiffRows.Row.line(Self.fileLine($0)) }
        #expect(open.files[0].rows == [.gap(0), .line(3), .line(4), .line(5), .line(6), .line(7)] + lines
            + [.gapLess(1), .line(8), .line(9), .line(10), .line(11), .gap(2)])
        #expect(open.gaps[1].state == .open && open.gaps[1].ordinal == 1)
        #expect(open.gaps[2].title == "Show 6 hidden lines", "the text says where the file ends")

        let closed = DiffRows(document: document, threads: [])
        #expect(closed.files[0].rows.count == 12 && !closed.files[0].rows.contains(.gapLess(1)))
    }

    @Test func aGapIsNoRowsUntilItsFilesTextIsHere() {
        let asked = DiffRows.Hidden(gaps: [DiffRows.GapID(path: "f.txt", first: 9)], loading: ["f.txt"])
        let rows = DiffRows(document: Self.document, threads: [], hidden: asked)
        #expect(rows.files[0].rows.count == 12)
        #expect(rows.gaps.allSatisfy { $0.state == .loading }, "its file is being read")
    }

    @Test func aFailedReadIsSaidOnTheGapItWasAskedFrom() {
        var hidden = DiffRows.Hidden()
        hidden.failures["f.txt"] = .init(first: 9, words: "This file is binary.")
        let rows = DiffRows(document: Self.document, threads: [], hidden: hidden)
        #expect(rows.gaps.map(\.state) == [.closed, .failed("This file is binary."), .closed])
        hidden.failures["f.txt"] = .init(first: nil, words: "This file is too large to show.")
        let whole = DiffRows(document: Self.document, threads: [], hidden: hidden)
        #expect(whole.gaps.map(\.state) == [.failed("This file is too large to show."), .closed, .closed])
    }

    @Test func aWholeFileIsEveryLineAndGoesBackToItsHunks() {
        let document = Self.document.showing(Self.head(), forFile: 0)
        let whole = DiffRows(document: document, threads: [], hidden: .init(files: ["f.txt"]))
        let shown = whole.files[0].rows.compactMap(\.codeLine).map { document.lines[$0] }
        #expect(shown.filter { $0.kind != .hunk && $0.kind != .removed }.map(\.newLine) == Array(1 ... 20))
        #expect(!whole.files[0].rows.contains { row in
            if case .gap = row {
                return true
            }
            if case .gapLess = row {
                return true
            }
            return false
        }, "its menu puts it back, not a row")
        #expect(whole.files[0].showsWhole == true)
        let back = DiffRows(document: document, threads: [])
        #expect(back.files[0].rows.count == 12 && back.files[0].showsWhole == false)
    }

    /// Offered until the text is read: after a hunk that turns out to end the file there is nothing to show.
    @Test func aGapAfterTheLastHunkGoesWhenTheFileEndsThere() {
        let document = Self.document.showing(Self.head(14), forFile: 0)
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.gaps.map(\.id.first) == [1, 9])
        #expect(rows.files[0].rows.last == .line(11))

        let all = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+line 1\n".utf8))
        #expect(DiffRows(document: all, threads: []).files[0].showsWhole == false)
        let read = DiffRows(document: all.showing(Self.head(1), forFile: 0), threads: [])
        #expect(read.gaps.isEmpty && read.files[0].showsWhole == nil, "the diff was the whole file")
    }

    @Test func changedLinesOnlyLeavesRevealedLinesOutButOneWithAComment() throws {
        let document = Self.document.showing(Self.head(), forFile: 0)
        let hidden = DiffRows.Hidden(files: ["f.txt"])
        let rows = DiffRows(document: document, threads: [], changedLinesOnly: true, hidden: hidden)
        #expect(rows.files[0].rows == [.line(3), .line(5), .line(8), .line(9), .line(10)])
        #expect(DiffRows(document: Self.document, threads: [], changedLinesOnly: true).gaps.isEmpty)

        let commented = try DiffRows(
            document: document, threads: [Self.thread(line: 10)], changedLinesOnly: true, hidden: hidden
        )
        #expect(commented.files[0].rows == [
            .line(3), .line(5), .line(Self.fileLine(10)), .thread(0), .line(8), .line(9), .line(10),
        ])
    }

    @Test func aThreadAndAKeyLineOnARevealedLineSitUnderIt() throws {
        let document = Self.document.showing(Self.head(), forFile: 0)
        // On line 10 of the new file, and on line 15 of the old one, which is line 16 of the new.
        let threads = try [Self.thread(line: 10), Self.thread(line: 15, side: "LEFT")]
        let note = try JSONDecoder().decode(PRKeyLines.Item.self, from: Data(
            #"{"path":"f.txt","line":17,"side":"RIGHT","kind":"risk","why":"w"}"#.utf8
        ))
        let closed = DiffRows(document: document, threads: threads, note: note)
        #expect(!closed.files[0].rows.contains(.thread(0)) && closed.noteLine == nil, "no line to sit under yet")

        let open = DiffRows(document: document, threads: threads, note: note, hidden: .init(files: ["f.txt"]))
        let rows = open.files[0].rows
        let place = { (row: DiffRows.Row) in rows.firstIndex(of: row) ?? -1 }
        #expect(place(.thread(0)) == place(.line(Self.fileLine(10))) + 1)
        #expect(place(.thread(1)) == place(.line(Self.fileLine(16))) + 1)
        #expect(open.noteLine == Self.fileLine(17) && place(.note) == place(.line(Self.fileLine(17))) + 1)
        // What a jump to the key line looks for: the line by its file and number, then its row.
        let found = document.lines.firstIndex { $0.file == 0 && $0.newLine == 17 }
        #expect(found == Self.fileLine(17))
    }

    @Test func aPendingCommentOnARevealedLineIsPlacedOnceItsGapIsOpen() {
        let document = Self.document.showing(Self.head(), forFile: 0)
        let draft = PRPendingComment(PRDraftComment(id: UUID(), path: "f.txt", line: 10, side: .right, body: "b"))
        #expect(DiffRows(document: document, threads: [], pending: [draft]).placed.isEmpty)
        let open = DiffRows(document: document, threads: [], pending: [draft], hidden: .init(files: ["f.txt"]))
        #expect(open.placed == [draft.id])
    }

    // MARK: - Long gaps and long lines

    @Test func aLongGapOpensAsItsEndsRoundTheRest() {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3001 +3001 @@\n-a\n+b\n"
        let document = DiffDocument(data: Data(text.utf8)).showing(Self.head(3001), forFile: 0)
        let id = DiffRows.GapID(path: "f", first: 1)
        let cut = DiffRows(document: document, threads: [], hidden: .init(gaps: [id]))
        let rows = cut.files[0].rows
        #expect(DiffRows.gapLimit == 2000 && DiffRows.gapEdge == 200)
        #expect(rows.count == 200 + 1 + 200 + 1 + 3, "its first and last 200, the row between, Show less, the hunk")
        #expect(rows[200] == .gapMore(0) && rows[401] == .gapLess(0))
        #expect(cut.gaps[0].moreTitle == "Show 2,600 more lines")
        #expect(document.lines[rows[199].codeLine ?? 0].newLine == 200)
        #expect(document.lines[rows[201].codeLine ?? 0].newLine == 2801)

        let full = DiffRows(document: document, threads: [], hidden: .init(gaps: [id], full: [id]))
        #expect(full.files[0].rows.count == 3000 + 1 + 3)
        #expect(!full.files[0].rows.contains(.gapMore(0)))

        let short = DiffDocument(data: Data(text.replacing("3001", with: "2001").utf8)).showing(Self.head(2001), forFile: 0)
        let whole = DiffRows(document: short, threads: [], hidden: .init(gaps: [id]))
        #expect(whole.files[0].rows.count == 2000 + 1 + 3, "2,000 lines are shown whole")
    }

    /// A revealed line too long for a row is cut and opened as a diff's own is.
    @Test func aVeryLongRevealedLineIsPiecesUnderShowFullLine() {
        let long = String(repeating: #"{"id":1,"type":"timeseries"},"#, count: 400)
        let text = Data("short\n\(long)\nlast\n".utf8)
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3 +3 @@\n-a\n+last\n".utf8))
            .showing(text, forFile: 0)
        let index = document.diffLineCount + 1
        #expect(document.opensCut(index))
        let pieces = (0 ..< document.pieceCount(ofLine: index)).map { document.text(ofLine: index, piece: $0) }
        #expect(pieces.joined() == " " + long, "drawn after the space an unchanged line of a diff starts with")
        #expect(pieces.allSatisfy { $0.utf8.count <= DiffDocument.pieceBytes + 1 })
        #expect(document.byteCount(ofLine: index, piece: 0) == pieces[0].utf8.count)
        #expect(document.isPlain(line: index, piece: 0) && document.isMinified(line: index, piece: 1))
        #expect(document.indentColumns(of: document.lines[index]) == 1)

        let hidden = DiffRows.Hidden(files: ["f"])
        let cut = DiffRows(document: document, threads: [], hidden: hidden)
        #expect(cut.cut == [index] && cut.files[0].rows.contains(.rest(index)))
        let id = DiffRows.LineID(document.lines[index], in: document)
        let whole = DiffRows(document: document, threads: [], longLines: .init(whole: [id]), hidden: hidden)
        #expect(whole.files[0].rows.contains(.piece(index, 1)) && whole.files[0].rows.contains(.less(index)))
    }

    @Test func aRevealedLinesIndentIsCountedFromItsOwnFirstCharacter() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3 +3 @@\n-a\n+b\n".utf8))
            .showing(Data("    four\n\ttab\n".utf8), forFile: 0)
        #expect(document.indentColumns(of: document.lines[document.diffLineCount]) == 5)
        #expect(document.indentColumns(of: document.lines[document.diffLineCount + 1]) == 4)
        #expect(!document.isPlain(line: document.diffLineCount + 1, piece: 0), "a tab is not one column")
    }
}
