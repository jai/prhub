import DurableNetworking
import Foundation
@testable import PRKit
import PRKitTestSupport
import Synchronization
import Testing

/// A PR's pending review kept the same on GitHub and on this device (`PRPendingSync`), through the host's outbox: a
/// comment shows at once and goes to GitHub, a refusal stays on it through a relaunch, GitHub wins for what it has,
/// and a Worker without pending reviews gets what it always got.
@MainActor
struct PRPendingSyncTests {
    private typealias Host = PROutboxJobTests.Host

    /// An outbox that can stop a job, as PRHub's can before the job's first try.
    @MainActor
    final class StoppingOutbox: PRKitOutbox {
        private(set) var jobs: [(id: String, job: PROutboxJob)] = []
        private(set) var stopped: [String] = []

        func enqueue(_ job: PROutboxJob) async throws -> String {
            jobs.append(("job-\(jobs.count + 1)", job))
            return jobs[jobs.count - 1].id
        }

        func isQueued(_: PROutboxJob.Kind, about _: PullRequestRef) -> Bool {
            false
        }

        func cancel(_ id: String) async -> Bool {
            stopped.append(id)
            return true
        }

        func holds(job id: String, about _: PullRequestRef) -> Bool {
            jobs.contains { $0.id == id } && !stopped.contains(id)
        }
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private let clock = TestClock()
    private let drafts = InMemoryFileStore()
    private static let locked = "GitHub didn't take the comment on src/a.ts. Its line may no longer be in the diff."

    /// A kit over this test's draft store, so a second one is the app launched again.
    private func kit(outbox: (any PRKitOutbox)? = nil) -> (PRKitController, Host) {
        let host = Host()
        let storage = PRKitStorage(
            mirror: InMemoryFileStore(), kept: InMemoryKeptStore(), drafts: drafts, settings: InMemoryKeyValueStore()
        )
        let kit = PRKitController(host: host, storage: storage, network: PRNetwork(isOnline: true))
        let clock = clock
        kit.model.sleep = { try await clock.sleep(for: $0) }
        if let outbox {
            kit.model.outbox = outbox
        }
        return (kit, host)
    }

    private static func comment(
        _ id: String, _ body: String, line: Int? = 12, thread: String? = nil, file: Bool = false
    ) -> String {
        let line = line.map(String.init) ?? "null"
        let thread = thread.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","path":"src/a.ts","line":\(line),"side":"RIGHT","body":"\(body)",
        "createdAt":"2026-11-20T10:00:00Z","outdated":false,"thread":\(thread),"file":\(file)}
        """
    }

    /// A detail from a Worker that reads pending reviews, holding `comments`; `pending` nil is an older Worker's.
    private static func detail(_ comments: [String] = [], supportsPending: Bool = true, threads: String = "[]") -> Data {
        let review = comments.isEmpty ? "null" : #"{"id":"PRR_1","body":"","comments":[\#(comments.joined(separator: ","))]}"#
        let plain = PRTestPayload.detail(id: "PR_1")
            .replacing(#""reviewThreads":{"nodes":[]}"#, with: #""reviewThreads":{"nodes":\#(threads)}"#)
        let json = supportsPending
            ? plain.replacing(#""title":null}"#, with: #""title":null,"pendingReview":\#(review)}"#) : plain
        return Data(json.utf8)
    }

    private static let diff = "diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -12 +12 @@\n-old\n+new\n"

    private func session(_ kit: PRKitController, _ detail: Data) throws -> PRSession {
        let content = try PRContent(
            detail: PullRequestDetail.decode(detail), document: DiffDocument(data: Data(Self.diff.utf8))
        )
        return PRSession(ref: ref, title: nil, content: content, tappedAt: 0, model: kit.model)
    }

    private func writes(_ host: Host) -> [PRWrite] {
        host.held.jobs.compactMap { held in
            if case let .write(write, _) = held.job {
                return write
            }
            return nil
        }
    }

    private func payloads(_ writes: [PRWrite]) -> [[String: AnyHashable]] {
        writes.map { write in
            (try? JSONEncoder().encode(write))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: AnyHashable] } ?? [:]
        }
    }

    /// Waits until the outbox holds `count` jobs and the newest is being waited on.
    private func queued(_ count: Int, _ kit: PRKitController, _ host: Host) async throws {
        try await settle("\(count) jobs in the outbox") {
            host.held.jobs.count == count && kit.model.waiting.contains("job-\(count)")
        }
    }

    private func add(_ session: PRSession, _ body: String = "Why twice?") {
        session.addPendingComment(body: body, path: "src/a.ts", line: 12, side: .right)
    }

    // MARK: - Add

    @Test func aCommentShowsAtOnceThenLandsOnGitHubAndLeavesTheDevice() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        #expect(session.usesPendingReview && session.pending.isEmpty)
        add(session)
        #expect(session.pending.map(\.body) == ["Why twice?"], "shown before anything is sent")
        #expect(session.pending.map(\.sync) == [.waiting])
        #expect(kit.model.draftStore.load(ref).count == 1, "saved on the device first")
        try await queued(1, kit, host)
        #expect(payloads(writes(host)) == [[
            "kind": "pending_add", "pullRequest": "PR_1", "path": "src/a.ts", "line": 12, "side": "RIGHT",
            "body": "Why twice?",
        ]])
        #expect(kit.model.draftStore.load(ref).first?.sync?.job == "job-1", "its job is kept with it")

        kit.outboxAnswered(id: "job-1", data: Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        try await settle("the comment is GitHub's") { session.pending.map(\.sync) == [.synced] }
        #expect(session.pending.map(\.origin) == [.github("PRRC_1")])
        #expect(kit.model.draftStore.loadPending(ref).isEmpty, "the device copy is dropped")
        #expect(kit.model.draftStore.owner(ofJob: "job-1") == nil)
        #expect(host.held.jobs.count == 1, "sent once")
        guard case let .document(_, rows)? = session.content?.diff else {
            Issue.record("no diff")
            return
        }
        #expect(rows.files[0].rows.contains(.draft(0)) && rows.placed == ["PRRC_1"])
    }

    /// No outbox, as in a host without one: the write goes straight to the Worker, and offline it fails.
    @Test func offlineACommentWaitsAndGoesWhenTheNetworkIsBack() async throws {
        let isOnline = Shared(false)
        let posts = Shared<[Data]>([])
        let landed = Self.detail([Self.comment("PRRC_1", "Why twice?")])
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test") }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { request in
            guard isOnline.value else {
                throw URLError(.notConnectedToInternet)
            }
            let url = try #require(request.url)
            let isWrite = url.path().hasSuffix("/write")
            if isWrite {
                posts.change { $0.append(request.httpBody ?? Data()) }
            }
            let body = isWrite ? landed : Data(#"{"prs":[],"synced_at":0}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let network = PRNetwork(isOnline: false)
        let model = PRsModel(client: client, storage: .inMemory(), network: network)
        let content = try PRContent(detail: PullRequestDetail.decode(Self.detail()), document: nil)
        let session = PRSession(ref: ref, title: nil, content: content, tappedAt: 0, model: model)
        add(session)
        await model.pendingSync.sync(ref).value
        #expect(session.pending.map(\.sync) == [.waiting], "not failed: nobody refused it")
        #expect(model.draftStore.load(ref).first?.isUnsent == true)
        #expect(posts.value.isEmpty)

        isOnline.value = true
        network.update(true)
        try await settle("the comment landed") { session.pending.map(\.sync) == [.synced] }
        #expect(posts.value.count == 1)
        #expect(model.draftStore.loadPending(ref).isEmpty)
        #expect(session.pendingOffDiff.map(\.id) == ["PRRC_1"], "with no diff the page lists it")
    }

    // MARK: - Refusals

    @Test func aRefusalInTimeLeavesTheCommentWithItsReasonAndTryAgainSendsIt() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        add(session)
        try await queued(1, kit, host)
        kit.outboxRefused(id: "job-1", kind: .write, reason: Self.locked)
        try await settle("the comment is marked failed") { session.pending.first?.failure != nil }
        #expect(session.pending.map(\.sync) == [.failed(Self.locked)])
        #expect(session.pending.map(\.body) == ["Why twice?"], "never dropped")
        #expect(session.pendingGoing == 0 && session.pendingNotGoing == 1)
        #expect(kit.model.lateRefusal == nil, "said on the comment")
        await kit.model.pendingSync.sync(ref).value
        #expect(host.held.jobs.count == 1, "a refused comment is not sent again by itself")

        session.retryPending(session.pending[0])
        #expect(session.pending.map(\.sync) == [.waiting])
        try await queued(2, kit, host)
        kit.outboxAnswered(id: "job-2", data: Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        try await settle("the retry landed") { session.pending.map(\.sync) == [.synced] }
    }

    @Test func aRefusalAfterARelaunchStillMarksTheCommentAndTryAgainSendsIt() async throws {
        let (first, firstHost) = kit()
        try add(session(first, Self.detail()))
        try await queued(1, first, firstHost)
        try await clock.advance(by: first.model.answerWait, afterSleepers: 1)
        try await settle("the wait ended with the add still going") { first.model.waiting.isEmpty }

        // The app again: nothing in memory, the outbox's refusal comes before any screen is open.
        let (kit, host) = kit()
        kit.outboxRefused(id: "job-1", kind: .write, reason: Self.locked)
        #expect(kit.model.draftStore.load(ref).first?.sync == PRDraftSync(failure: Self.locked), "kept with the comment")
        #expect(kit.model.lateRefusal == "GitHub refused a write: \(Self.locked)")

        let session = try session(kit, Self.detail())
        #expect(session.pending.map(\.sync) == [.failed(Self.locked)], "visible, with the reason")
        await kit.model.pendingSync.sync(ref).value
        #expect(host.held.jobs.isEmpty, "not sent again until asked")
        session.retryPending(session.pending[0])
        try await queued(1, kit, host)
        #expect(payloads(writes(host)).map { $0["body"] } == ["Why twice?"])
    }

    @Test func aRefusedLineCommentCanGoOnItsFileInstead() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        add(session)
        try await queued(1, kit, host)
        kit.outboxRefused(id: "job-1", kind: .write, reason: Self.locked)
        try await settle("the comment is marked failed") { session.pending.first?.failure != nil }
        session.addPendingToFile(session.pending[0])
        #expect(session.pending.map(\.sync) == [.waiting] && session.pending[0].isFile)
        try await queued(2, kit, host)
        #expect(payloads(writes(host))[1] == [
            "kind": "pending_add", "pullRequest": "PR_1", "path": "src/a.ts", "file": true, "body": "Line 12: Why twice?",
        ])
    }

    // MARK: - GitHub's and the device's

    @Test func gitHubsPendingCommentsAndTheDevicesAreOneList() async throws {
        let (kit, host) = kit()
        let thread = """
        [{"id":"PRRT_1","isResolved":false,"path":"src/a.ts","line":12,"diffSide":"LEFT","comments":{"nodes":[
        {"id":"c","author":null,"body":"Old?","createdAt":"2026-11-20T10:00:00Z"}]}}]
        """
        let session = try session(kit, Self.detail([
            Self.comment("PRRC_1", "On the line"), Self.comment("PRRC_2", "On the file", line: nil, file: true),
            Self.comment("PRRC_3", "A reply", line: nil, thread: "PRRT_1"), Self.comment("PRRC_4", "Outdated", line: 40),
        ], threads: thread))
        add(session, "Mine")
        try await queued(1, kit, host)
        #expect(session.pending.map(\.body) == ["On the line", "On the file", "A reply", "Outdated", "Mine"])
        #expect(session.pendingGoing == 5, "GitHub's count too")
        guard case let .document(_, rows)? = session.content?.diff else {
            Issue.record("no diff")
            return
        }
        // The removed line carries the thread and its pending reply; the added one the two line comments.
        #expect(rows.files[0].rows == [.line(3), .line(4), .thread(0), .draft(2), .line(5), .draft(0), .draft(4)])
        #expect(session.pendingOffDiff.map(\.id) == ["PRRC_2", "PRRC_4"], "the page lists what the diff has no line for")
        #expect(session.pendingReplies(to: "PRRT_1").map(\.id) == ["PRRC_3"])
    }

    @Test func aCommentOnNoPhoneAndNotOnGitHubIsSentAgainAndOneGitHubShowsIsNot() async throws {
        let lost = PRDraftComment(
            id: UUID(), path: "src/a.ts", line: 12, side: .right, body: "Lost?", sync: PRDraftSync(job: "gone-1", sent: "Lost?")
        )
        let landed = PRDraftComment(
            id: UUID(), path: "src/a.ts", line: 12, side: .right, body: "Landed", sync: PRDraftSync(job: "gone-2", sent: "Landed")
        )
        PRDraftStore(store: drafts).save([lost, landed], for: ref)
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "Landed")]))
        #expect(session.pending.map(\.body) == ["Landed", "Lost?"])
        #expect(session.pending.map(\.sync) == [.synced, .waiting])
        try await queued(1, kit, host)
        #expect(payloads(writes(host)).map { $0["body"] } == ["Lost?"], "sent again; the landed one is not")
    }

    @Test func aDraftFromAnOlderVersionIsSentToThePendingReview() async throws {
        let old = #"[{"id":"7B0E8D6C-3C1B-4C55-9B62-0C1D0E5B7A11","path":"src/a.ts","line":12,"side":"RIGHT","body":"Old one"}]"#
        try drafts.write(Data(old.utf8), to: "acme__api__7.json")
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        #expect(session.pending.map(\.body) == ["Old one"])
        try await queued(1, kit, host)
        #expect(payloads(writes(host)).map { $0["kind"] } == ["pending_add"])
    }

    // MARK: - Edit and delete

    @Test func anEditOfGitHubsCommentShowsAtOnceAndIsKeptUntilGitHubHasIt() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        session.editPending(session.pending[0], body: "Why two times?")
        try await queued(1, kit, host)
        #expect(session.pending.map(\.body) == ["Why two times?"] && session.pending.map(\.sync) == [.waiting])
        #expect(kit.model.draftStore.loadPending(ref).changes.map(\.job) == ["job-1"], "durable, with its job")
        #expect(payloads(writes(host)) == [["kind": "pending_edit", "comment": "PRRC_1", "body": "Why two times?"]])
        kit.outboxAnswered(id: "job-1", data: Self.detail([Self.comment("PRRC_1", "Why two times?")]))
        try await settle("GitHub has the edit") { session.pending.map(\.sync) == [.synced] }
        #expect(session.pending.map(\.body) == ["Why two times?"])
        #expect(kit.model.draftStore.loadPending(ref).isEmpty)
    }

    @Test func aDeleteOfGitHubsCommentHidesItAndARefusalBringsItBack() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        session.removePending(session.pending[0])
        try await queued(1, kit, host)
        #expect(session.pending.isEmpty, "gone at once")
        #expect(payloads(writes(host)) == [["kind": "pending_delete", "comment": "PRRC_1"]])
        kit.outboxRefused(id: "job-1", kind: .write, reason: "Not allowed")
        try await settle("the comment is back") { !session.pending.isEmpty }
        #expect(session.pending.map(\.sync) == [.failed("Not allowed")])
        #expect(session.pendingGoing == 1 && session.pendingChangesRefused == 1, "GitHub still has it, so it still goes")
    }

    @Test func aChangeToACommentGitHubNoLongerHoldsIsDroppedNotFailed() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        session.editPending(session.pending[0], body: "Why two times?")
        try await queued(1, kit, host)
        try await clock.advance(by: kit.model.answerWait, afterSleepers: 1)
        try await settle("the wait ended") { kit.model.waiting.isEmpty }
        kit.outboxRefused(
            id: "job-1", kind: .write, reason: "That comment is no longer in your unsent review. Refresh the PR."
        )
        #expect(session.pending.isEmpty, "GitHub wins: it is not in the pending review any more")
        #expect(kit.model.draftStore.loadPending(ref).isEmpty)
        #expect(kit.model.lateRefusal == nil, "nothing failed")
    }

    @Test func aDeviceCommentChangedBeforeItsAddWentIsStoppedAndSentWithTheNewWords() async throws {
        let outbox = StoppingOutbox()
        let (kit, _) = kit(outbox: outbox)
        let session = try session(kit, Self.detail())
        add(session)
        try await settle("the add is in the outbox") { kit.model.waiting.contains("job-1") }
        session.editPending(session.pending[0], body: "Why two times?")
        #expect(session.pending.map(\.body) == ["Why twice?"] || session.pending.map(\.body) == ["Why two times?"])
        try await settle("sent again with the new words") { outbox.jobs.count == 2 }
        #expect(outbox.stopped == ["job-1"])
        guard case let .write(.pendingAdd(_, _, _, _, body), _) = outbox.jobs[1].job else {
            Issue.record("expected an add")
            return
        }
        #expect(body == "Why two times?" && session.pending.map(\.body) == ["Why two times?"])
    }

    @Test func aDeviceCommentChangedOrDeletedTooLateToStopIsFollowedOnceItLands() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        add(session)
        try await queued(1, kit, host)
        session.editPending(session.pending[0], body: "Why two times?")
        try await settle("the new words show") { session.pending.map(\.body) == ["Why two times?"] }
        #expect(host.held.jobs.count == 1, "this outbox can't stop a job, so nothing is sent twice")
        kit.outboxAnswered(id: "job-1", data: Self.detail([Self.comment("PRRC_1", "Why twice?")]))
        try await queued(2, kit, host)
        #expect(payloads(writes(host))[1] == ["kind": "pending_edit", "comment": "PRRC_1", "body": "Why two times?"])
        #expect(session.pending.map(\.body) == ["Why two times?"] && session.pending.map(\.origin) == [.github("PRRC_1")])

        add(session, "Second")
        try await queued(3, kit, host)
        session.removePending(session.pending[1])
        try await settle("the second is gone at once") { session.pending.count == 1 }
        kit.outboxAnswered(id: "job-3", data: Self.detail([
            Self.comment("PRRC_1", "Why two times?"), Self.comment("PRRC_2", "Second"),
        ]))
        try await queued(4, kit, host)
        #expect(payloads(writes(host))[3] == ["kind": "pending_delete", "comment": "PRRC_2"])
        #expect(session.pending.map(\.id) == ["PRRC_1"])
    }

    // MARK: - Submit

    @Test func aReviewGoesAfterWhatIsStillUnsentAndCarriesOnlyItsWords() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "GitHub's")]))
        add(session, "Mine")
        try session.submitReview("Not yet.", to: PRReviewAction.requestChanges.target(hasDrafts: session.pendingGoing > 0))
        try await queued(2, kit, host)
        #expect(payloads(writes(host)) == [
            ["kind": "pending_add", "pullRequest": "PR_1", "path": "src/a.ts", "line": 12, "side": "RIGHT", "body": "Mine"],
            ["kind": "pending_submit", "event": "REQUEST_CHANGES", "body": "Not yet."],
        ])
        #expect(kit.model.reviewToast?.words == "Submitting review…")

        // GitHub refuses the review: the words come back, and the comments are where they were.
        kit.outboxAnswered(id: "job-1", data: Self.detail([Self.comment("PRRC_1", "GitHub's"), Self.comment("PRRC_2", "Mine")]))
        kit.outboxRefused(id: "job-2", kind: .write, reason: "Pull request is locked")
        try await settle("the toast failed") { kit.model.reviewToast?.phase == .failed("Pull request is locked") }
        #expect(session.text(for: .review(.requestChanges)).wrappedValue == "Not yet.")
        #expect(session.pending.map(\.body) == ["GitHub's", "Mine"] && session.pending.map(\.sync) == [.synced, .synced])

        // Retry: GitHub takes it, and its pending review is gone with it.
        let retry = try #require(kit.model.retryReview())
        try await queued(3, kit, host)
        #expect(payloads(writes(host)).last?["kind"] == AnyHashable("pending_submit"))
        kit.outboxAnswered(id: "job-3", data: Self.detail())
        await retry.value
        #expect(kit.model.reviewToast?.words == "Changes requested")
        #expect(session.pending.isEmpty)
    }

    @Test func commentNowOnALineAddsItThenSubmits() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail())
        try session.submitReview("Why twice?", to: .line(path: "src/a.ts", line: 12, side: .right))
        try await queued(2, kit, host)
        #expect(payloads(writes(host)).map { $0["kind"] } == ["pending_add", "pending_submit"])
        #expect(payloads(writes(host))[1] == ["kind": "pending_submit", "event": "COMMENT", "body": ""])
    }

    @Test func aReviewDoesNotPretendARefusedCommentGoes() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail([Self.comment("PRRC_1", "GitHub's")]))
        add(session, "Mine")
        try await queued(1, kit, host)
        kit.outboxRefused(id: "job-1", kind: .write, reason: Self.locked)
        try await settle("the comment is marked failed") { session.pendingNotGoing == 1 }
        #expect(session.pendingGoing == 1, "only GitHub's goes")
        #expect(PRPendingWords.refused(comments: session.pendingNotGoing, changes: session.pendingChangesRefused) != nil)
        try session.submitReview("", to: .review(.approve))
        try await queued(2, kit, host)
        #expect(payloads(writes(host)).map { $0["kind"] } == ["pending_add", "pending_submit"], "not sent again")
        #expect(session.pending.map(\.body) == ["GitHub's", "Mine"], "and still there, failed")
    }

    // MARK: - A Worker without pending reviews

    @Test func withoutTheKeyCommentsWaitOnTheDeviceAndGoInOneReview() async throws {
        let (kit, host) = kit()
        let session = try session(kit, Self.detail(supportsPending: false))
        #expect(!session.usesPendingReview)
        #expect(PRPendingWords.addTitle(usesPendingReview: false, hasPending: session.pending.isEmpty == false) == "Start review")
        session.addDraft("Why twice?", on: .line(path: "src/a.ts", line: 12, side: .right))
        await kit.model.pendingSync.sync(ref).value
        #expect(host.held.jobs.isEmpty, "nothing goes until the review does")
        #expect(session.pending.map(\.body) == ["Why twice?"] && session.drafts.count == 1)
        #expect(kit.model.draftStore.load(ref).first?.sync == nil)

        try session.submitReview("", to: PRReviewAction.approve.target(hasDrafts: true))
        try await queued(1, kit, host)
        #expect(payloads(writes(host)) == [[
            "kind": "review", "event": "APPROVE", "body": "", "commit": "h",
            "comments": [["path": "src/a.ts", "line": 12, "side": "RIGHT", "body": "Why twice?"]] as [[String: AnyHashable]],
        ]])
        #expect(session.pending.isEmpty && kit.model.draftStore.load(ref).isEmpty)
        kit.outboxRefused(id: "job-1", kind: .write, reason: "Pull request is locked")
        try await settle("the toast failed") { kit.model.reviewToast?.phase == .failed("Pull request is locked") }
        #expect(session.pending.map(\.body) == ["Why twice?"], "a refusal gives the comment back, as before")
    }
}

/// A value a test's closures share.
private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func change(_ change: (inout Value) -> Void) {
        state.withLock { change(&$0) }
    }
}
