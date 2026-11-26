import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A key line's words made into a comment of the review not submitted yet: the press opens the line's box with the
/// words in it and keeps nothing; the box's own button keeps them; the control is ticked from the review's pending
/// comments and never adds a second; a line the diff does not show gets a comment on its file.
@MainActor
struct PRKeyLineDraftTests {
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

    private let shown = PRKeyLines.Item(
        path: "src/checkout/payments.ts", line: 12, side: "RIGHT", kind: "risk",
        why: "The retry relies on the server ignoring a second payment."
    )
    /// A line the model named that this diff does not show, as after a newer commit.
    private let gone = PRKeyLines.Item(
        path: "src/checkout/payments.ts", line: 99, side: "RIGHT", kind: "decision", why: "Is the limit meant?"
    )

    /// The sample PR's session. `pendingReview`: the detail's value for the key, or nil for a Worker without pending
    /// reviews, whose detail has no such key.
    private func session(pendingReview: String? = "null") throws -> PRSession {
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Show a retry button", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: nil
        )
        let detail = pendingReview.map {
            PRTestPayload.detail().replacing(#""title":null}"#, with: #""title":null,"pendingReview":\#($0)}"#)
        } ?? PRTestPayload.detail()
        let samples = PRSampleSet(
            samples: [.init(row: row, detail: detail, diff: Self.diff, keyLines: nil)], mergedReviewed: [],
            mergedMine: [], answersOnPhone: true
        )
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let session = model.session(for: row)
        try #require(session.content != nil)
        return session
    }

    private var target: PRComposerTarget {
        .line(path: shown.path, line: shown.line, side: .right)
    }

    // MARK: - The press

    @Test func thePressOpensTheLinesBoxWithTheKeyLinesWordsAndKeepsNothing() throws {
        let session = try session()
        #expect(session.offersAddToReview(shown) && session.pendingComment(on: shown) == nil)
        #expect(session.addToReview(shown) == .openedBox)
        guard case let .line(index, _, line, side) = session.place(of: shown) else {
            Issue.record("The diff shows this line")
            return
        }
        #expect(session.composingLine == index && line == 12 && side == .right, "the line's own box")
        #expect(session.text(for: target).wrappedValue == shown.why, "to be changed before it is kept")
        #expect(session.jump?.path == shown.path && session.jump?.line == 12, "the diff goes to the line")
        #expect(session.selectedKeyLine?.id == shown.id)
        #expect(session.pending.isEmpty && session.drafts.isEmpty, "nothing is kept until the box's own button")
        #expect(session.pendingComment(on: shown) == nil, "so it is not ticked yet")
    }

    @Test func wordsAlreadyWaitingInTheBoxAreNotReplaced() throws {
        let session = try session()
        session.text(for: target).wrappedValue = "My own half-written words"
        #expect(session.addToReview(shown) == .openedBox)
        #expect(session.text(for: target).wrappedValue == "My own half-written words")
    }

    @Test func theBoxsButtonKeepsItAsOnePendingCommentAndASecondPressShowsThatOne() async throws {
        let session = try session()
        session.addToReview(shown)
        session.addDraft("The retry relies on the server. Is that guaranteed?", on: target)
        session.composingLine = nil
        #expect(session.pending.map(\.body) == ["The retry relies on the server. Is that guaranteed?"], "shown at once")
        #expect(session.pendingComment(on: shown) != nil, "ticked, from the review's list")
        try await settle("GitHub's pending review has it") { session.pending.first?.sync == .synced }
        #expect(session.pendingComment(on: shown)?.origin != nil && session.pending.count == 1)

        #expect(session.addToReview(shown) == .shownUnderItsLine)
        #expect(session.composingLine == nil, "no second box")
        #expect(session.text(for: target).wrappedValue.isEmpty, "and no second copy of the words")
        #expect(session.pending.count == 1)
        #expect(session.jump?.line == 12, "the diff goes to the comment's line")
    }

    @Test func aCommentBegunOnGitHubTicksTheKeyLineToo() throws {
        let begun = """
        {"id":"R_1","body":"","comments":[{"id":"C_1","path":"src/checkout/payments.ts","line":12,"side":"RIGHT",
        "body":"Why?","outdated":false,"thread":null,"file":false}]}
        """
        let session = try session(pendingReview: begun)
        #expect(session.pendingComment(on: shown)?.origin == .github("C_1"))
        #expect(session.addToReview(shown) == .shownUnderItsLine && session.composingLine == nil)
        #expect(session.pendingComment(on: gone) == nil, "another line of the file is not ticked by it")
    }

    // MARK: - A line the diff does not show

    @Test func aLineNotInTheDiffGetsTheSameBoxForACommentOnItsFile() async throws {
        let session = try session()
        #expect(session.place(of: gone) == .file && session.offersAddToReview(gone))
        #expect(session.addToReview(gone) == .openedBox)
        #expect(session.composingOffDiff?.id == gone.id && session.composingLine == nil)
        #expect(session.offDiffText(for: gone).wrappedValue == gone.why)
        #expect(session.pending.isEmpty, "nothing is kept yet")

        session.addToFile("Is the limit meant? I think not.", for: gone)
        #expect(session.composingOffDiff == nil && session.offDiffText(for: gone).wrappedValue.isEmpty)
        let kept = try #require(session.pending.first)
        #expect(kept.isFile && kept.line == nil && kept.path == gone.path)
        #expect(kept.body == "Line 99: Is the limit meant? I think not.", "its words say which line")
        try await settle("GitHub's pending review has it, on the file") {
            session.content?.detail.pendingReview.comments.map(\.isFile) == [true]
        }
        #expect(session.pendingOffDiff.count == 1, "listed on the PR's page")

        let asks = session.pendingListShows
        #expect(session.addToReview(gone) == .listedOnThePage, "ticked, and a press goes to it")
        #expect(session.pendingListShows == asks + 1 && session.composingOffDiff == nil && session.pending.count == 1)
        #expect(session.pendingComment(on: shown) == nil)
    }

    // MARK: - A Worker without pending reviews

    @Test func onAnOlderWorkerTheSamePressAddsADeviceDraft() throws {
        let session = try session(pendingReview: nil)
        #expect(!session.usesPendingReview)
        #expect(session.addToReview(shown) == .openedBox)
        #expect(session.text(for: target).wrappedValue == shown.why && session.drafts.isEmpty)
        session.addDraft(shown.why, on: target)
        #expect(session.drafts.map(\.body) == [shown.why] && session.drafts.first?.line == 12, "kept on this device")
        #expect(session.pendingComment(on: shown)?.sync == .waiting, "and ticked from it")
        #expect(session.addToReview(shown) == .shownUnderItsLine && session.drafts.count == 1)
    }

    @Test func onAnOlderWorkerALineNotInTheDiffHasNoPlaceForAComment() throws {
        let session = try session(pendingReview: nil)
        #expect(!session.offersAddToReview(gone))
        #expect(session.addToReview(gone) == .nothing)
        #expect(session.composingOffDiff == nil && session.composingLine == nil && session.drafts.isEmpty)
    }

    // MARK: - The control's words

    @Test func theControlReadsTheSameBeforeAndAfterAndOnlyItsIconChanges() {
        #expect(PRKeyLineAddButton.title == "Add to review")
        #expect(PRKeyLineAddButton.icon(isAdded: false) == .compose && PRKeyLineAddButton.icon(isAdded: true) == .done)
        #expect(PRKeyLineAddButton.value(isAdded: true) == "added" && PRKeyLineAddButton.value(isAdded: false) == "not added")
    }
}
