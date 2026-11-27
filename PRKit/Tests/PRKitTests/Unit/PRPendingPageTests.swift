import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// What a PR's page says of the review not submitted yet, for a PR that comes with one begun on github.com (as the
/// sample acme/web#412 does): the line over the review's buttons counts every pending comment, and the page's list
/// holds the ones with no line in the diff to sit under, each with where it belongs.
@MainActor
struct PRPendingPageTests {
    private let ref = PullRequestRef(repo: "acme/web", number: 412)

    private static let diff = """
    diff --git a/src/checkout/payments.ts b/src/checkout/payments.ts
    --- a/src/checkout/payments.ts
    +++ b/src/checkout/payments.ts
    @@ -10,2 +10,4 @@ export async function pay(order) {
       return api.post(url);
     }
    +// The server ignores a second payment for the same order.
    +export const retries = true;

    """

    /// One comment on line 13 of the diff's file, one on the whole of a file.
    private static let review = """
    {"id":"R_1","body":"","comments":[
    {"id":"C_1","path":"src/checkout/payments.ts","line":13,"side":"RIGHT","body":"Should a retry stop?",
    "createdAt":"2026-11-26T08:00:00Z","outdated":false,"thread":null,"file":false},
    {"id":"C_2","path":"src/checkout/CheckoutError.tsx","line":null,"side":"RIGHT","body":"This file could use a test.",
    "createdAt":"2026-11-26T09:00:00Z","outdated":false,"thread":null,"file":true}]}
    """

    private func session(review: String = PRPendingPageTests.review, diff: String = PRPendingPageTests.diff) throws -> PRSession {
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Show a retry button", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: nil
        )
        let detail = PRTestPayload.detail().replacing(#""title":null}"#, with: #""title":null,"pendingReview":\#(review)}"#)
        let samples = PRSampleSet(
            samples: [.init(row: row, detail: detail, diff: diff, keyLines: nil)], mergedReviewed: [], mergedMine: [],
            answersOnPhone: true
        )
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let session = model.session(for: row)
        try #require(session.content != nil)
        return session
    }

    @Test func theReviewCountsEveryPendingCommentGitHubHolds() throws {
        let session = try session()
        #expect(session.pending.map(\.id) == ["C_1", "C_2"])
        #expect(session.pendingGoing == 2 && session.pendingNotGoing == 0)
        #expect(PRPendingWords.going(session.pendingGoing) == "2 pending comments will go with your review")
        #expect(try self.session(review: "null").pendingGoing == 0, "no review begun: nothing is said")
    }

    @Test func thePagesListHoldsOnlyTheCommentsWithNoLineInTheDiff() throws {
        let session = try session()
        let listed = session.pendingOffDiff
        #expect(listed.map(\.id) == ["C_2"], "the other sits under its line in the diff")
        #expect(listed.first?.location == "src/checkout/CheckoutError.tsx", "the file's path, with no line")
        #expect(listed.first?.body == "This file could use a test.")
    }

    @Test func whereGitHubSentNoDiffThePageListsEveryPendingComment() throws {
        let session = try session(diff: "")
        #expect(session.pendingOffDiff.map(\.id) == ["C_1", "C_2"])
        #expect(session.pendingOffDiff.first?.location == "src/checkout/payments.ts:13")
    }
}
