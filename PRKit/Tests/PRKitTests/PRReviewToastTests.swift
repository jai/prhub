import Foundation
import Testing
@testable import PRKit

/// A review sent from its box, which has already closed: the toast says each step, a late answer or refusal still
/// reaches it, a refusal stays with Retry, and the line comments come back if it fails.
@MainActor
struct PRReviewToastTests {
    private typealias Host = PROutboxJobTests.Host
    private let ref = PullRequestRef(repo: "acme/toast-\(UUID().uuidString.prefix(8))", number: 7)
    private let approve = PRWrite.review(.approve, body: "", commit: "c", comments: [])
    private static let detail = Data("""
    {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
    "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
    "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
    """.utf8)

    private func kit(wait: Duration = .milliseconds(50), isOnline: Bool = true) -> (PRKitController, Host) {
        let host = Host()
        let kit = PRKitController(host: host)
        kit.model.answerWait = wait
        kit.model.isOnline = { isOnline }
        return (kit, host)
    }

    private func until(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func submit(
        _ kit: PRKitController, _ write: PRWrite, drafts: [PRDraftComment] = [],
        settled: @escaping @MainActor (PRReviewToast.Phase) -> Void = { _ in }
    ) {
        kit.model.submitReview(write, to: ref, drafts: drafts, head: "h", answer: "approved") { phase, _ in
            settled(phase)
        }
    }

    @Test func itSaysSubmittingThenApprovedThenGoes() async {
        let (kit, host) = kit(wait: .seconds(5))
        submit(kit, approve)
        #expect(kit.model.reviewToast?.words == "Submitting review…")
        await until { !host.held.jobs.isEmpty }
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        await until { kit.model.reviewToast?.phase == .done }
        #expect(kit.model.reviewToast?.words == "Approved")
        #expect(kit.model.reviewToast?.tone == .toneGood)
        await until { kit.model.reviewToast == nil }
        #expect(kit.model.reviewToast == nil, "it fades once GitHub has it")
    }

    @Test func eachKindSaysWhatLanded() {
        let toast = { (write: PRWrite) in
            PRReviewToast(ref: ref, write: write, drafts: [], head: "h", answer: nil, phase: .done) { _, _ in }.words
        }
        #expect(toast(approve) == "Approved")
        #expect(toast(.review(.requestChanges, body: "x", commit: "c", comments: [])) == "Changes requested")
        #expect(toast(.review(.comment, body: "x", commit: "c", comments: [])) == "Comment posted")
        #expect(toast(.comment(body: "x")) == "Comment posted")
        let comment = PRReviewToast(ref: ref, write: .comment(body: "x"), drafts: [], head: "h", answer: nil) { _, _ in }
        #expect(comment.words == "Posting comment…")
    }

    @Test func anAnswerAfterTheWaitStillLandsTheToast() async {
        let (kit, host) = kit()
        submit(kit, approve)
        await until { kit.model.reviewToast?.job != nil }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(kit.model.reviewToast?.phase == .sending, "past the wait it is still sending, never red")
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        #expect(kit.model.reviewToast?.phase == .done)
    }

    @Test func offlineItSaysItGoesWhenOnline() async {
        let (kit, _) = kit(isOnline: false)
        submit(kit, approve)
        await until { kit.model.reviewToast?.phase == .waitingForNetwork }
        #expect(kit.model.reviewToast?.words == "Saved on this phone. It goes when you're online.")
        #expect(kit.model.reviewToast?.tone == .toneWaiting)
    }

    @Test func aLateRefusalStaysOnTheToastWithRetryAndGivesTheCommentsBack() async {
        let (kit, host) = kit()
        let draft = PRDraftComment(id: UUID(), path: "a.swift", line: 3, side: .right, body: "Why?")
        var settled: [PRReviewToast.Phase] = []
        submit(kit, .review(.approve, body: "", commit: "c", comments: [draft]), drafts: [draft]) { settled.append($0) }
        await until { kit.model.reviewToast?.job != nil }
        try? await Task.sleep(for: .milliseconds(150))
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        #expect(kit.model.reviewToast?.words == "Review not sent. Pull request is locked")
        #expect(kit.model.lateRefusal == nil, "said on the toast, not again on the list")
        #expect(host.events == [.writeRefused("GitHub refused your review on \(ref.repo)#7: Pull request is locked")])
        #expect(PRDraftStore().load(ref) == [draft], "its line comment is back on the PR")
        #expect(settled == [.failed("Pull request is locked")])

        kit.model.retryReview()
        #expect(kit.model.reviewToast?.phase == .sending)
        #expect(PRDraftStore().load(ref).isEmpty, "Retry sends the comment again")
        await until { kit.model.reviewToast?.job == "job-2" }
        kit.outboxAnswered(id: host.held.jobs[1].id, data: Self.detail)
        await until { kit.model.reviewToast?.phase == .done }
        #expect(kit.model.reviewToast?.phase == .done)
        #expect(settled == [.failed("Pull request is locked"), .sending, .done])
        PRDraftStore().save([], for: ref)
    }

    @Test func aRefusalInTimeFailsTheToast() async {
        let (kit, host) = kit(wait: .seconds(5))
        submit(kit, approve)
        await until { !host.held.jobs.isEmpty }
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        await until { kit.model.reviewToast?.phase != .sending }
        #expect(kit.model.reviewToast?.phase == .failed("Pull request is locked"))
        kit.model.dismissReviewToast()
        #expect(kit.model.reviewToast == nil)
    }
}
