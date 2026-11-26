import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A pending comment's card brought whole into view in the diff: when GitHub refuses the comment, its reason and its
/// buttons grow the card downwards, and when its edit box closes the card shrinks. Either way the diff is asked to
/// show the card, so its buttons are not left under the floating controls (the coordinator's picture, 2026-11-26).
@MainActor
struct PRPendingRevealTests {
    private let ref = PullRequestRef(repo: "acme/web", number: 412)
    private static let path = "src/checkout/payments.ts"

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

    private func comment(_ id: String, line: Int? = 12, sync: PRPendingComment.Sync) -> PRPendingComment {
        PRPendingComment(origin: .github(id), path: Self.path, line: line, side: .right, body: "Why?", sync: sync)
    }

    /// The sample PR's session; `refusal` set, a pending comment on a line is refused in those words.
    private func session(refusing refusal: String? = nil) throws -> PRSession {
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Show a retry button", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: nil
        )
        let detail = PRTestPayload.detail().replacing(#""title":null}"#, with: #""title":null,"pendingReview":null}"#)
        var samples = PRSampleSet(
            samples: [.init(row: row, detail: detail, diff: Self.diff, keyLines: nil)], mergedReviewed: [],
            mergedMine: [], answersOnPhone: true
        )
        samples.refusesLinePendingAdds = refusal
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let session = model.session(for: row)
        try #require(session.content != nil)
        return session
    }

    @Test func aCommentIsNewlyFailedOnlyWhenItWasThereAndNotRefused() {
        let waiting = comment("a", sync: .waiting)
        let failed = comment("a", sync: .failed("Its line may no longer be in the diff."))
        #expect([failed].newlyFailed(since: [waiting])?.id == "a")
        #expect([failed].newlyFailed(since: [failed]) == nil, "refused before: nothing new")
        #expect([failed].newlyFailed(since: []) == nil, "a PR opened with a refused comment moves nothing")
        #expect([waiting].newlyFailed(since: [waiting]) == nil)
        #expect([comment("b", sync: .synced), failed].newlyFailed(since: [comment("b", sync: .synced), waiting])?.id == "a")
    }

    @Test func theRowsSayWhereAPendingCommentsCardIs() {
        let document = DiffDocument(data: Data(Self.diff.utf8))
        let onLine = comment("a", sync: .waiting)
        let onFile = comment("b", line: nil, sync: .waiting)
        let rows = DiffRows(document: document, threads: [], pending: [onFile, onLine])
        let place = rows.place(ofPending: "a")
        #expect(place?.file == 0)
        #expect(place.map { rows.files[0].rows[$0.row] } == .draft(1), "the card's own row, under its line")
        #expect(place.map { rows.files[0].rows[$0.row - 1].codeLine.map { document.lines[$0].newLine } } == 12)
        #expect(rows.place(ofPending: "b") == nil, "a comment on the file has no row in the diff")
        #expect(rows.place(ofPending: "nobody") == nil)
    }

    @Test func aRefusedCommentsCardIsBroughtIntoViewInTheDiff() async throws {
        let session = try session(refusing: "Its line may no longer be in the diff.")
        session.isDiffOnScreen = true
        session.addPendingComment(body: "Why?", path: Self.path, line: 12, side: .right)
        #expect(session.jump == nil, "a comment on its way moves nothing")
        try await settle("GitHub's refusal reaches the card") { session.pending.first?.failure != nil }
        let refused = try #require(session.pending.first)
        #expect(session.jump?.pending == refused.id && session.jump?.path == Self.path)
        #expect(session.jump?.line == nil, "the card is shown, not its line moved to the middle")
    }

    @Test func aRefusalWithTheDiffOffScreenAsksForNoScroll() async throws {
        let session = try session(refusing: "Its line may no longer be in the diff.")
        session.addPendingComment(body: "Why?", path: Self.path, line: 12, side: .right)
        try await settle("GitHub's refusal reaches the card") { session.pending.first?.failure != nil }
        #expect(session.jump == nil, "the next diff to open would have jumped to it")
    }

    @Test func aCommentGitHubTakesMovesNothing() async throws {
        let session = try session()
        session.isDiffOnScreen = true
        session.addPendingComment(body: "Why?", path: Self.path, line: 12, side: .right)
        try await settle("GitHub's pending review has it") { session.pending.first?.sync == .synced }
        #expect(session.jump == nil)
    }

    @Test func aPendingCommentsEditBoxClosingBringsItsCardIntoView() async throws {
        let session = try session()
        session.isDiffOnScreen = true
        session.addPendingComment(body: "Why?", path: Self.path, line: 12, side: .right)
        try await settle("GitHub's pending review has it") { session.pending.first?.sync == .synced }
        let kept = try #require(session.pending.first)
        let box = session.editText(for: kept)
        box.wrappedValue = nil
        #expect(session.jump == nil, "a box that was not open closes nothing")
        box.wrappedValue = kept.body
        #expect(session.jump == nil, "opening it moves nothing")
        box.wrappedValue = nil
        #expect(session.jump?.pending == kept.id, "Cancel, and Save, which closes it the same way")
    }
}
