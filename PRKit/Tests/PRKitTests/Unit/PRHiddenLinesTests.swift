import Foundation
@testable import PRKit
import PRKitTestSupport
import Synchronization
import Testing

/// "Show N hidden lines" and "Show whole file" on an open PR: nothing is read when the diff opens, a file's text is
/// read once and kept, a read that fails says why on its gap's row, and a comment on a line the diff does not show is
/// kept for the review on the line's file.
@MainActor
struct PRHiddenLinesTests {
    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private nonisolated static let path = "src/PR+Diff.swift"
    private nonisolated static let head = String(repeating: "a", count: 40)

    /// One hunk in the middle of a file of twenty lines: lines 1 to 9 and 13 to 20 are left out.
    nonisolated static let diff = """
    diff --git a/\(path) b/\(path)
    --- a/\(path)
    +++ b/\(path)
    @@ -10,3 +10,3 @@
     line 10
    -old
    +line 11
     line 12

    """

    nonisolated static let text = (1 ... 20).map { "line \($0)\n" }.joined()

    /// The Worker's `file` route, and its detail for a PR read again.
    final class Worker: Sendable {
        struct State {
            var fileURLs: [URL] = []
            var paths: [String] = []
            /// A status and body to answer `file` with; nil is the file's text.
            var refusal: (status: Int, body: String)?
            var allowsFile = true
            var detail = Data()
        }

        private let state = Mutex(State())

        var fileURLs: [URL] {
            state.withLock { $0.fileURLs }
        }

        var paths: [String] {
            state.withLock { $0.paths }
        }

        func refuse(_ status: Int, _ body: String = "") {
            state.withLock { $0.refusal = (status, body) }
        }

        func answer() {
            state.withLock { $0.refusal = nil }
        }

        /// While false, a read of a file fails the test: nothing may read one before the reader asks.
        func allowFile(_ allows: Bool) {
            state.withLock { $0.allowsFile = allows }
        }

        func serve(detail: Data) {
            state.withLock { $0.detail = detail }
        }

        func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let now = state.withLock { state in
                state.paths.append(url.path)
                if url.path.hasSuffix("/file") {
                    state.fileURLs.append(url)
                }
                return state
            }
            let answer = { (status: Int, body: Data) in
                (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard url.path.hasSuffix("/file") else {
                return url.path.hasSuffix("/diff") ? answer(200, Data(PRHiddenLinesTests.diff.utf8)) : answer(200, now.detail)
            }
            if !now.allowsFile {
                Issue.record("a file was read before the reader asked for one")
            }
            if let refusal = now.refusal {
                return answer(refusal.status, Data(refusal.body.utf8))
            }
            return answer(200, Data(PRHiddenLinesTests.text.utf8))
        }
    }

    private let worker = Worker()
    private let storage = PRKitStorage.inMemory()

    private static func detail(head: String = head, pending: Bool = true) -> Data {
        let plain = PRTestPayload.detail(id: "PR_1", head: head)
        return Data((pending ? plain.replacing(#""title":null}"#, with: #""title":null,"pendingReview":null}"#) : plain).utf8)
    }

    private func model() -> PRsModel {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { try await worker.exchange($0) }
        return PRsModel(client: client, storage: storage, network: PRNetwork(isOnline: true))
    }

    private func session(_ model: PRsModel? = nil, pending: Bool = true) throws -> PRSession {
        let content = try PRContent(
            detail: PullRequestDetail.decode(Self.detail(pending: pending)), document: DiffDocument(data: Data(Self.diff.utf8))
        )
        return PRSession(ref: ref, title: nil, content: content, tappedAt: 0, model: model ?? self.model())
    }

    private func rows(_ session: PRSession) throws -> (document: DiffDocument, rows: DiffRows) {
        guard case let .document(document, rows)? = session.content?.diff else {
            throw PRLocalRefusal.notLoaded
        }
        return (document, rows)
    }

    private func gap(_ ordinal: Int, of session: PRSession) throws -> DiffRows.Gap {
        try #require(try rows(session).rows.gaps.first { $0.ordinal == ordinal })
    }

    /// The new file's numbers of the lines from the file's text that are rows.
    private func revealed(_ session: PRSession) throws -> [Int] {
        let (document, rows) = try rows(session)
        return rows.files[0].rows.compactMap(\.codeLine).map { document.lines[$0] }.filter(\.isOutsideDiff).map(\.newLine)
    }

    // MARK: - Opening

    @Test func openingADiffReadsNoFile() async throws {
        worker.allowFile(false)
        let session = try session()
        await session.loadIfNeeded()
        let (document, rows) = try rows(session)
        #expect(rows.gaps.map(\.title) == ["Show 9 hidden lines", "Show hidden lines"], "from the hunk's header alone")
        #expect(document.texts.isEmpty && document.lines.count == document.diffLineCount)
        session.setChangedLinesOnly(true)
        session.setChangedLinesOnly(false)
        session.setWrapsLongLines(false)
        #expect(worker.fileURLs.isEmpty && worker.paths.isEmpty, "nothing is asked of the Worker")
    }

    // MARK: - One gap

    @Test func aPressReadsTheFileOnceAndShowsTheGapsLines() async throws {
        let session = try session()
        try session.toggle(gap(0, of: session))
        #expect(try gap(0, of: session).state == .loading, "its row turns while the file is read")
        #expect(try gap(0, of: session).title == "Show 9 hidden lines", "and reads the same")
        try await settle("the gap opens") { (try? self.revealed(session)) == Array(1 ... 9) }
        let url = try #require(worker.fileURLs.first)
        #expect(url.path == "/prs/acme/api/7/file")
        #expect(url.query(percentEncoded: true)?.contains("path=src/PR%2BDiff.swift") == true, "\(url)")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "head" }?.value == Self.head)
        #expect(try gap(1, of: session).title == "Show 8 hidden lines", "the text says where the file ends")

        // The other gap of the same file, and the whole file: rows again, and no second read.
        try session.toggle(gap(1, of: session))
        #expect(try revealed(session) == Array(1 ... 9) + Array(13 ... 20))
        session.setWholeFile(true, path: Self.path)
        #expect(worker.fileURLs.count == 1, "read once for the PR's every row")

        // "Show less" under a gap's lines closes it. The whole file still shows every line until its menu is off.
        session.setWholeFile(false, path: Self.path)
        try session.toggle(gap(0, of: session))
        #expect(try revealed(session) == Array(13 ... 20))
        #expect(try gap(0, of: session).state == .closed)
    }

    @Test func theTextIsKeptOnTheDeviceForTheNextTimeThePROpens() async throws {
        let model = model()
        let first = try session(model)
        first.setWholeFile(true, path: Self.path)
        try await settle("the file shows whole") { (try? self.revealed(first))?.count == 17 }
        #expect(storage.kept.load(PRsModel.fileKey(Self.path, head: Self.head, of: ref))?.data == Data(Self.text.utf8))

        worker.allowFile(false)
        let again = try session(model)
        #expect(try rows(again).rows.files[0].showsWhole == false, "a new open starts with nothing shown")
        try again.toggle(gap(0, of: again))
        try await settle("from the device") { (try? self.revealed(again)) == Array(1 ... 9) }
        #expect(worker.fileURLs.count == 1)
    }

    // MARK: - A whole file

    @Test func showWholeFileOpensEveryGapAndGoesBack() async throws {
        let session = try session()
        #expect(try rows(session).rows.files[0].showsWhole == false)
        session.setWholeFile(true, path: Self.path)
        try await settle("every line shows") { (try? self.revealed(session)) == Array(1 ... 9) + Array(13 ... 20) }
        #expect(try rows(session).rows.files[0].showsWhole == true)
        #expect(try rows(session).rows.gaps.allSatisfy { $0.state == .open })
        session.setWholeFile(false, path: Self.path)
        #expect(try revealed(session).isEmpty)
        #expect(try rows(session).rows.files[0].showsWhole == false)
    }

    // MARK: - Failures

    @Test(arguments: [
        (413, #"{"error":{"code":"too_large","message":"the file is over 1 MB"}}"#, "This file is too large to show."),
        (415, #"{"error":{"code":"binary_file","message":"the file is not text"}}"#, "This file is binary."),
        (404, #"{"error":{"code":"not_found","message":"no file"}}"#, "There is no file at this path to show."),
        (404, "Not found", "The Worker can't answer this yet. Try again, or update your Worker."),
        (503, "", "The Worker couldn't answer just now. Try again in a minute."),
    ])
    func aReadThatFailsSaysWhyOnTheGapsRow(status: Int, body: String, words: String) async throws {
        let session = try session()
        worker.refuse(status, body)
        try session.toggle(gap(1, of: session))
        try await settle("the failure shows") { (try? self.gap(1, of: session))?.state == .failed(words) }
        #expect(try gap(0, of: session).state == .closed, "on the gap that was pressed")
        #expect(try revealed(session).isEmpty)

        // Try again asks again, and shows what was asked for.
        worker.answer()
        try session.retry(gap(1, of: session))
        try await settle("the gap opens") { (try? self.revealed(session)) == Array(13 ... 20) }
        #expect(worker.fileURLs.count == 2)
    }

    @Test func aWholeFileThatCantBeReadSaysSoOnItsFirstGap() async throws {
        let session = try session()
        worker.refuse(413, #"{"error":{"code":"too_large","message":"m"}}"#)
        session.setWholeFile(true, path: Self.path)
        try await settle("the failure shows") {
            (try? self.gap(0, of: session))?.state == .failed("This file is too large to show.")
        }
        #expect(try rows(session).rows.files[0].showsWhole == false)
        worker.answer()
        try session.retry(gap(0, of: session))
        try await settle("the whole file shows") { (try? self.rows(session))?.rows.files[0].showsWhole == true }
    }

    /// `409 head_moved`: the PR has a newer commit, so it is read again, as its key lines do.
    @Test func atACommitThePRHasLeftThePRIsReadAgain() async throws {
        let session = try session()
        let newer = String(repeating: "b", count: 40)
        worker.serve(detail: Self.detail(head: newer))
        worker.refuse(409, #"{"error":{"code":"head_moved","message":"head is not this PR's head commit"}}"#)
        try session.toggle(gap(0, of: session))
        try await settle("the newer commit shows") { session.content?.detail.head == newer }
        #expect(worker.paths.contains("/prs/acme/api/7/detail") && worker.paths.contains("/prs/acme/api/7/diff"))
        #expect(try rows(session).rows.gaps.allSatisfy { $0.state == .closed }, "nothing opened, nothing failed")
        #expect(session.hiddenLines.head == newer && session.hiddenLines.texts.isEmpty)
    }

    // MARK: - Comments

    @Test func aCommentOnARevealedLineIsKeptForItsFileWithTheLineInItsWords() async throws {
        let session = try session()
        session.setWholeFile(true, path: Self.path)
        try await settle("every line shows") { (try? self.revealed(session))?.count == 17 }
        let (document, _) = try rows(session)
        let index = try #require(document.lines.firstIndex { $0.isOutsideDiff && $0.newLine == 15 })
        session.compose(index, in: document)
        #expect(session.composingLine == index, "its box opens")

        session.addPendingOnFile("Why here?", path: Self.path, line: 15)
        let comment = try #require(session.pending.last)
        #expect(comment.body == "Line 15: Why here?" && comment.isFile && comment.line == nil)
        #expect(comment.path == Self.path)
        #expect(session.pendingOffDiff.map(\.id) == [comment.id], "the PR's page lists it, as it does a file's comment")
        try await settle("it is sent to GitHub's review") { self.worker.paths.contains("/prs/acme/api/7/write") }
    }

    @Test func withoutAReviewOnGitHubARevealedLineTakesNoComment() async throws {
        let session = try session(pending: false)
        #expect(!session.usesPendingReview)
        session.setWholeFile(true, path: Self.path)
        try await settle("every line shows") { (try? self.revealed(session))?.count == 17 }
        let (document, _) = try rows(session)
        let hidden = try #require(document.lines.firstIndex { $0.isOutsideDiff && $0.newLine == 15 })
        session.compose(hidden, in: document)
        #expect(session.composingLine == nil, "GitHub would refuse a comment on it")
        let shown = try #require(document.lines.firstIndex { !$0.isOutsideDiff && $0.newLine == 11 })
        session.compose(shown, in: document)
        #expect(session.composingLine == shown, "a line of the diff takes one as before")
    }

    // MARK: - Samples

    @Test func aSampleAnswersFromThePhoneAndCanRefuseAFile() async throws {
        let row = PullRequestRow(repo: "acme/api", number: 7, title: "t", head: "h", revision: "r", diff: .ready, detail: "d", status: nil)
        let sample = PRSampleSet.Sample(
            row: row, detail: String(decoding: Self.detail(), as: UTF8.self), diff: Self.diff, keyLines: nil,
            files: [Self.path: Self.text]
        )
        var samples = PRSampleSet(samples: [sample], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
        #expect(try samples.fileText(Self.path, for: ref) == Data(Self.text.utf8))
        #expect(throws: PRFileProblem.missing) { try samples.fileText("other.swift", for: ref) }
        samples.failsFileReads[Self.path] = .tooLarge

        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let session = try session(model)
        try session.toggle(gap(0, of: session))
        try await settle("the failure shows") {
            (try? self.gap(0, of: session))?.state == .failed("This file is too large to show.")
        }
    }
}
