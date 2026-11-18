import Foundation
@testable import PRKit
import Testing

struct PRReviewToastPolicyTests {
    private let ref = PullRequestRef(repo: "acme/toast", number: 7)
    private let approve = PRWrite.review(.approve, body: "", commit: "c", comments: [])

    @Test func aLinesCommentNowIsAComment() {
        let line = PRWrite.line(path: "a.swift", line: 3, side: .right, body: "nit", commit: "c")
        let toast = { (phase: PRReviewToast.Phase) in
            PRReviewToast(ref: ref, write: line, drafts: [], head: "h", answer: nil, phase: phase) { _, _ in }
        }
        #expect(toast(.sending).words == "Posting comment…")
        #expect(toast(.done).words == "Comment posted")
        #expect(toast(.failed("no")).words == "Comment not sent. no")
    }

    @Test func theBarFollowsAReviewGoingOrLandedOnly() {
        let toast = { (phase: PRReviewToast.Phase) in
            PRReviewToast(ref: ref, write: approve, drafts: [], head: "h", answer: nil, phase: phase) { _, _ in }
        }
        #expect(toast(.sending).showsProgress)
        #expect(toast(.done).showsProgress)
        #expect(!toast(.waitingForNetwork).showsProgress)
        #expect(!toast(.failed("no")).showsProgress)
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
}
