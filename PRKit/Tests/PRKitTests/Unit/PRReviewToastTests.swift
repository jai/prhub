import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A review sent from its box, which has already closed: the toast says each step, a late answer or refusal still
/// reaches it, a refusal stays with Retry, and the line comments come back if it fails.
@MainActor
struct PRReviewToastTests {
    private typealias Host = PROutboxJobTests.Host
    private let ref = PullRequestRef(repo: "acme/toast-\(UUID().uuidString.prefix(8))", number: 7)
    private let approve = PRWrite.review(.approve, body: "", commit: "c", comments: [])
    /// The model's clock: the answer wait and the toast's dwell end only when a test moves it on.
    private let clock = TestClock()
    private static let detail = Data("""
    {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
    "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
    "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
    """.utf8)

    private func kit(wait: Duration = .seconds(15), isOnline: Bool = true) -> (PRKitController, Host) {
        let host = Host()
        let kit = PRKitController(host: host, storage: .inMemory(), network: PRNetwork(isOnline: isOnline))
        kit.model.answerWait = wait
        let clock = clock
        kit.model.sleep = { try await clock.sleep(for: $0) }
        kit.model.isOnline = { isOnline }
        return (kit, host)
    }

    /// The answer wait passes with no answer.
    private func passTheWait(_ kit: PRKitController) async throws {
        try await clock.advance(by: kit.model.answerWait, afterSleepers: 1)
    }

    /// A landed toast's dwell passes.
    private func passTheDwell() async throws {
        try await clock.advance(by: ToastStyle.dwell, afterSleepers: 1)
    }

    private func submit(
        _ kit: PRKitController, _ write: PRWrite, drafts: [PRDraftComment] = [],
        settled: @escaping @MainActor (PRReviewToast.Phase) -> Void = { _ in }
    ) -> Task<Void, Never> {
        kit.model.submitReview(write, to: ref, drafts: drafts, head: "h", answer: "approved") { phase, _ in
            settled(phase)
        }
    }

    @Test func itSaysSubmittingThenApprovedThenGoes() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sending = submit(kit, approve)
        #expect(kit.model.reviewToast?.words == "Submitting review…")
        try await settle("outbox registered a waiting review") { !kit.model.waiting.isEmpty }
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        await sending.value
        #expect(kit.model.reviewToast?.phase == .done)
        #expect(kit.model.reviewToast?.words == "Approved")
        #expect(kit.model.reviewToast?.tone == .toneGood)
        try await passTheDwell()
        try await settle("landed toast dismissed") { kit.model.reviewToast == nil }
        #expect(kit.model.reviewToast == nil, "it fades once GitHub has it")
    }

    @Test func anAnswerAfterTheWaitStillLandsTheToast() async throws {
        let (kit, host) = kit()
        let sending = submit(kit, approve)
        try await passTheWait(kit)
        await sending.value
        #expect(kit.model.waiting.isEmpty, "the initial answer wait has ended")
        #expect(kit.model.reviewToast?.phase == .sending, "past the wait it is still sending, never red")
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        #expect(kit.model.reviewToast?.phase == .done)
        try await passTheDwell()
        try await settle("late landed toast dismissed") { kit.model.reviewToast == nil }
    }

    @Test func offlineItSaysItGoesWhenOnline() async throws {
        let (kit, _) = kit(isOnline: false)
        let sending = submit(kit, approve)
        try await passTheWait(kit)
        await sending.value
        #expect(kit.model.reviewToast?.phase == .waitingForNetwork)
        #expect(kit.model.reviewToast?.words == "Saved on this phone. It goes when you're online.")
        #expect(kit.model.reviewToast?.tone == .toneWaiting)
    }

    @Test func aLateRefusalStaysOnTheToastWithRetryAndGivesTheCommentsBack() async throws {
        let (kit, host) = kit()
        let draft = PRDraftComment(id: UUID(), path: "a.swift", line: 3, side: .right, body: "Why?")
        var settled: [PRReviewToast.Phase] = []
        let sending = submit(kit, .review(.approve, body: "", commit: "c", comments: [draft]), drafts: [draft]) { settled.append($0) }
        try await passTheWait(kit)
        await sending.value
        #expect(kit.model.waiting.isEmpty, "the initial answer wait has ended")
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        #expect(kit.model.reviewToast?.words == "Review not sent. Pull request is locked")
        #expect(kit.model.lateRefusal == nil, "said on the toast, not again on the list")
        #expect(host.events == [
            .wrote(.approve, .queued), .writeRefused("GitHub refused your review on \(ref.repo)#7: Pull request is locked"),
        ])
        #expect(kit.model.draftStore.load(ref) == [draft], "its line comment is back on the PR")
        #expect(settled == [.failed("Pull request is locked")])

        let retry = try #require(kit.model.retryReview())
        #expect(kit.model.reviewToast?.phase == .sending)
        #expect(kit.model.draftStore.load(ref).isEmpty, "Retry sends the comment again")
        try await settle("retry registered in the outbox") { kit.model.waiting.contains("job-2") }
        kit.outboxAnswered(id: host.held.jobs[1].id, data: Self.detail)
        await retry.value
        #expect(kit.model.reviewToast?.phase == .done)
        #expect(settled == [.failed("Pull request is locked"), .sending, .done])
        try await passTheDwell()
        try await settle("retried toast dismissed") { kit.model.reviewToast == nil }
    }

    @Test func aRefusalInTimeFailsTheToast() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sending = submit(kit, approve)
        try await settle("outbox registered a waiting review") { !kit.model.waiting.isEmpty }
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        await sending.value
        #expect(kit.model.reviewToast?.phase == .failed("Pull request is locked"))
        kit.model.dismissReviewToast()
        #expect(kit.model.reviewToast == nil)
    }
}
