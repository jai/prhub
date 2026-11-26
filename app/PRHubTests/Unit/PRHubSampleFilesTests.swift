import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

/// A sample PR answers for its files' texts from the phone, and each text agrees with its diff: every unchanged or
/// added line the diff shows is that line of the text, so the lines the diff leaves out are numbered right beside it.
struct PRHubSampleFilesTests {
    private static let hidden = PRSampleSet.prHubHiddenLines(failsRates: false)

    @Test(arguments: PRSampleSet.prHub.samples.map(\.row.id) + ["acme/web#431"])
    func everyFileWithLinesLeftOutHasATextThatAgreesWithItsDiff(id: String) throws {
        let sample = try #require(Self.hidden.samples.first { $0.row.id == id })
        let ref = PullRequestRef(repo: sample.row.repo, number: sample.row.number)
        var document = DiffDocument(data: Data(sample.diff.utf8))
        for (file, path) in document.files.enumerated() where document.shapes[file].hidesLines {
            let text = try Self.hidden.fileText(path, for: ref)
            document = document.showing(text, forFile: file)
            let lines = String(decoding: text, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            for line in document.lines.prefix(document.diffLineCount) where line.file == file && line.newLine > 0 {
                #expect(document.text(of: line).dropFirst() == lines[line.newLine - 1], "\(path):\(line.newLine)")
            }
        }
        // Shown whole, each file is its every line once, in order.
        let rows = DiffRows(document: document, threads: [], hidden: .init(files: Set(document.files)))
        for (file, shown) in rows.files.enumerated() where document.shapes[file].hidesLines {
            let numbers = shown.rows.compactMap(\.codeLine).map { document.lines[$0].newLine }.filter { $0 > 0 }
            #expect(numbers == Array(1 ... (document.texts[file]?.count ?? 0)), "\(shown.path)")
        }
    }

    /// `-PRHubHiddenLines`' PR: lines left out before, between and after the hunks of one file, a file renamed with
    /// nothing changed, and one whose read `-PRHubFileTooLarge` fails.
    @Test func theHiddenLinesSampleHasEveryKindOfGap() throws {
        let sample = try #require(Self.hidden.samples.first)
        #expect(sample.row.id == "acme/web#431" && sample.row.status?.list == "review")
        let document = DiffDocument(data: Data(sample.diff.utf8))
        #expect(document.files == ["src/checkout/charge.ts", "src/billing/money.ts", "src/checkout/rates.json"])
        let rows = DiffRows(document: document, threads: [])
        // By file, then by place in it: the rows hold them in the order they were met.
        let gaps = rows.gaps.sorted { ($0.file, $0.ordinal) < ($1.file, $1.ordinal) }
        #expect(gaps.map { $0.identifier() } == [
            "diff-gap-0-0", "diff-gap-0-1", "diff-gap-0-2", "diff-gap-1-0", "diff-gap-2-0", "diff-gap-2-1",
        ])
        #expect(gaps.map(\.title) == [
            "Show 7 hidden lines", "Show 11 hidden lines", "Show hidden lines", "Show hidden lines",
            "Show 4 hidden lines", "Show hidden lines",
        ])
        #expect(rows.files.map(\.showsWhole) == [false, false, false])

        let ref = PullRequestRef(repo: "acme/web", number: 431)
        let failing = PRSampleSet.prHubHiddenLines(failsRates: true)
        #expect(throws: PRFileProblem.tooLarge) { try failing.fileText("src/checkout/rates.json", for: ref) }
        #expect(try failing.fileText("src/checkout/charge.ts", for: ref).count > 1000)
    }

    /// acme/web#412's `payments.ts` starts at line 10: nine lines over its hunk and five under it.
    @Test func theCheckoutSamplesPaymentsFileHasLinesOverAndUnderItsHunk() throws {
        let sample = try #require(PRSampleSet.prHub.samples.first { $0.row.id == "acme/web#412" })
        let text = try PRSampleSet.prHub.fileText("src/checkout/payments.ts", for: PullRequestRef(repo: "acme/web", number: 412))
        let document = DiffDocument(data: Data(sample.diff.utf8)).showing(text, forFile: 1)
        let rows = DiffRows(document: document, threads: [])
        #expect(rows.gaps.filter { $0.file == 1 }.map(\.title) == ["Show 9 hidden lines", "Show 5 hidden lines"])
    }
}
