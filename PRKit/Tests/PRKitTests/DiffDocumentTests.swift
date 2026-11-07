@testable import PRKit
import Foundation
import Testing

struct DiffDocumentTests {
    @Test func classifiesEveryLineOfATwoFileDiff() {
        let text = """
        diff --git a/one.txt b/one.txt
        index 111..222 100644
        --- a/one.txt
        +++ b/one.txt
        @@ -1,2 +1,2 @@
         kept
        -old
        +new
        --- removed line that looks like a header
        +++ added line that looks like a header
        \\ No newline at end of file
        diff --git a/two.txt b/two.txt
        new file mode 100644
        @@ -0,0 +1 @@
        +first

        """
        let document = DiffDocument(data: Data(text.utf8))

        #expect(document.lines.map(\.kind) == [
            .file, .meta, .meta, .meta, .hunk, .context, .removed, .added, .removed, .added, .meta,
            .file, .meta, .hunk, .added,
        ])
        #expect(document.text(of: document.lines[7]) == "+new")
        #expect(document.text(of: document.lines[14]) == "+first")
    }

    @Test func numbersLinesAndNamesTheirFile() {
        let text = """
        diff --git a/one.txt b/one.txt
        --- a/one.txt
        +++ b/one.txt
        @@ -10,3 +20,3 @@ context
         kept
        -old
        +new
        diff --git a/gone.txt b/gone.txt
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -last

        """
        let document = DiffDocument(data: Data(text.utf8))

        #expect(document.files == ["one.txt", "gone.txt"])
        #expect((document.lines[4].oldLine, document.lines[4].newLine) == (10, 20))
        #expect((document.lines[5].oldLine, document.lines[5].newLine) == (11, 0))
        #expect((document.lines[6].oldLine, document.lines[6].newLine) == (0, 21))
        #expect(document.lines[11].file == 1)
    }

    @Test func aThreadSitsUnderItsLineOnItsSide() throws {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -5,2 +5,2 @@\n-old\n+new\n same\n"
        let document = DiffDocument(data: Data(text.utf8))
        let thread = { (line: Int?, side: String) in
            try JSONDecoder().decode(PullRequestDetail.Thread.self, from: Data("""
            {"id":"t","isResolved":false,"path":"f","line":\(line.map(String.init) ?? "null"),"diffSide":"\(side)",\
            "comments":{"nodes":[]}}
            """.utf8))
        }
        let rows = DiffRows(document: document, threads: [
            try thread(5, "RIGHT"), try thread(5, "LEFT"), try thread(nil, "RIGHT"), try thread(900, "RIGHT"),
        ])

        #expect(rows.files.map(\.path) == ["f"])
        #expect(rows.files[0].rows == [.line(3), .line(4), .thread(1), .line(5), .thread(0), .line(6)])
    }

    @Test func aFileCountsItsChangesAndKeepsItsHeaderOnlyWhenThatIsAllItHas() {
        let text = """
        diff --git a/one b/one
        --- a/one
        +++ b/one
        @@ -1,2 +1,2 @@
         kept
        -old
        +new
        +more
        \\ No newline at end of file
        diff --git a/old name b/new name
        similarity index 100%
        rename from old name
        rename to new name

        """
        let document = DiffDocument(data: Data(text.utf8))
        let rows = DiffRows(document: document, threads: [])

        #expect(document.files == ["one", "new name"])
        #expect(rows.files[0].change == DiffDocument.FileChange(added: 2, removed: 1))
        #expect(rows.files[0].rows == [.line(3), .line(4), .line(5), .line(6), .line(7), .line(8)])
        #expect(rows.files[1].rows == [.line(10), .line(11), .line(12)])
    }

    @Test func aLongLineIsClippedAndStillReadsInFull() {
        let long = "+" + String(repeating: "x", count: 500)
        let document = DiffDocument(data: Data("diff --git a/f b/f\n@@ -0,0 +1 @@\n\(long)\n".utf8))
        let line = document.lines[2]

        #expect(document.isClipped(line))
        #expect(document.text(of: line, limit: DiffDocument.columns).count == 160)
        #expect(document.text(of: line) == long)
    }

    @Test func emptyDiffHasNoLines() {
        #expect(DiffDocument(data: Data()).lines.isEmpty)
    }
}
