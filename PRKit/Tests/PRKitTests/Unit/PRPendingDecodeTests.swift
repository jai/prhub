import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A detail's `pendingReview` (docs/api.md): absent from a Worker that does not read pending reviews, null when the
/// person has none, and otherwise their unsubmitted review. Which of the three decides how the app keeps comments.
struct PRPendingDecodeTests {
    private func detail(_ pending: String?) throws -> PullRequestDetail {
        let plain = PRTestPayload.detail()
        let json = pending.map { plain.replacing(#""title":null}"#, with: #""title":null,"pendingReview":\#($0)}"#) } ?? plain
        return try PullRequestDetail.decode(Data(json.utf8))
    }

    @Test func anOlderWorkersDetailHasNoKeyAndStillDecodes() throws {
        let detail = try detail(nil)
        #expect(detail.pendingReview == .unsupported)
        #expect(!detail.pendingReview.isSupported && detail.pendingReview.comments.isEmpty)
    }

    @Test func nullIsAWorkerThatReadsThemAndAPersonWithNone() throws {
        let detail = try detail("null")
        #expect(detail.pendingReview == PRPendingReviewAnswer.none)
        #expect(detail.pendingReview.isSupported)
    }

    @Test func aPendingReviewDecodesWithEachKindOfComment() throws {
        let detail = try detail("""
        {"id":"PRR_1","body":"","comments":[
          {"id":"PRRC_1","path":"src/a.ts","line":12,"side":"LEFT","body":"Why twice?",
           "createdAt":"2026-11-20T10:00:00Z","outdated":false,"thread":null,"file":false},
          {"id":"PRRC_2","path":"src/a.ts","line":null,"side":"RIGHT","body":"Add a test.",
           "createdAt":"2026-11-20T10:01:00Z","outdated":false,"thread":null,"file":true},
          {"id":"PRRC_3","path":"src/b.ts","line":null,"side":"RIGHT","body":"Still true?",
           "createdAt":"2026-11-20T10:02:00Z","outdated":true,"thread":"PRRT_9","file":false}]}
        """)
        guard case let .review(review) = detail.pendingReview else {
            Issue.record("expected a pending review")
            return
        }
        #expect(review.id == "PRR_1" && review.comments.map(\.id) == ["PRRC_1", "PRRC_2", "PRRC_3"])
        #expect(review.comments[0].line == 12 && review.comments[0].side == .left)
        #expect(review.comments[1].isFile && review.comments[1].line == nil)
        #expect(review.comments[2].isOutdated && review.comments[2].thread == "PRRT_9")
    }

    @Test func whatThisAppCannotReadIsLeftOutNotFatal() throws {
        let detail = try detail("""
        {"id":"PRR_1","comments":[
          {"id":"PRRC_1","path":"src/a.ts","line":12,"side":"SIDEWAYS","body":"Why twice?","later":"field"},
          {"path":"src/a.ts","body":"no id"},
          "not a comment"]}
        """)
        #expect(detail.pendingReview.comments.map(\.id) == ["PRRC_1"])
        #expect(detail.pendingReview.comments[0].side == .right)
        #expect(try self.detail(#""odd""#).pendingReview == PRPendingReviewAnswer.none, "the Worker reads them, so the key counts")
    }
}
