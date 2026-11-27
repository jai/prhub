import DurableNetworking
import Foundation
import ImageIO
@testable import PRKit
import PRKitCore
import SwiftUI
import Testing
#if SWIFT_PACKAGE
    import PRKitTestSupport
#endif

/// A comment of the review not submitted yet, drawn off screen in light and dark: its card under a line of the diff,
/// the one GitHub refused, the PR page's list of those with no line, and the line that counts them over the review's
/// buttons. Sample data only (acme/web#412). Each keeps a picture, `pending-<what>-<scheme>.png`.
///
/// A picture can't be read for its words: what the count says is `PRPendingListTests`', what the list holds is
/// `PRPendingPageTests`', and `PRKitPendingReviewUITests` reads both once on a real screen.
@MainActor
struct PRPendingCardRenderingTests {
    private static let width: CGFloat = 370
    private static let scale: CGFloat = 2
    /// Ink this far from the card's ground is words, not a button's faint fill.
    private static let ink = 90

    private func render(_ name: String?, _ view: some View, in scheme: ColorScheme) throws -> Bitmap {
        let renderer = ImageRenderer(content: view.frame(width: Self.width).environment(\.colorScheme, scheme))
        renderer.scale = Self.scale
        let image = try renderer.settledImage()
        if let name {
            try SamplePR.keep(image, named: "pending-\(name)-\(scheme)")
        }
        return try Bitmap(image)
    }

    private func pixel(_ points: CGFloat) -> Int {
        Int((points * Self.scale).rounded())
    }

    /// The card's first row: its mark, where it belongs, and Edit and Delete.
    private var header: Range<Int> {
        pixel(PRStyle.inset) ..< pixel(PRStyle.inset + PRStyle.controlHeight)
    }

    /// The card's last row of buttons: Try again, and what else a refusal offers.
    private func foot(_ bitmap: Bitmap) -> Range<Int> {
        rows(bitmap.height - pixel(PRStyle.inset + PRStyle.controlHeight), bitmap.height - pixel(PRStyle.inset))
    }

    /// The rows from `top` to `bottom`; none when a picture is too short to have them.
    private func rows(_ top: Int, _ bottom: Int) -> Range<Int> {
        max(top, 0) ..< max(top, bottom, 0)
    }

    /// The columns inside the card's border.
    private func inside(_ bitmap: Bitmap, from leading: Int? = nil) -> Range<Int> {
        let start = leading ?? pixel(4)
        return start ..< max(start, bitmap.width - pixel(4))
    }

    /// The card's ground, from the padding over its first row.
    private func ground(_ bitmap: Bitmap) -> Pixel {
        bitmap[bitmap.width / 2, pixel(PRStyle.inset / 2)]
    }

    /// The columns of `columns` with ink in `rows`.
    private func inked(_ bitmap: Bitmap, rows: Range<Int>, columns: Range<Int>) -> [Int] {
        let ground = ground(bitmap)
        let rows = rows.clamped(to: 0 ..< bitmap.height)
        return columns.filter { column in rows.contains { bitmap[column, $0].distance(to: ground) >= Self.ink } }
    }

    /// The runs of inked columns, a run ending where `gap` points have no ink: a button's words are one run.
    private func runs(_ columns: [Int], gap: CGFloat = 16) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for column in columns {
            if let last = runs.last, column - last.upperBound < pixel(gap) {
                runs[runs.count - 1] = last.lowerBound ... column
            } else {
                runs.append(column ... column)
            }
        }
        return runs
    }

    private func inkedRows(_ bitmap: Bitmap, rows: Range<Int>) -> Int {
        let ground = ground(bitmap)
        return rows.clamped(to: 0 ..< bitmap.height).count { row in
            inside(bitmap).contains { bitmap[$0, row].distance(to: ground) >= Self.ink }
        }
    }

    // MARK: - The card under its line

    @Test(arguments: [ColorScheme.light, .dark])
    func aPendingCommentIsACardWithItsMarkItsWordsAndEditAndDelete(_ scheme: ColorScheme) throws {
        let card = try render("card", PRPendingCard(comment: SamplePR.onLine, actions: .none), in: scheme)
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        #expect(ground(card).isNear(Pixel(Color.groundCard.resolve(in: environment))), "a card, on the card's ground")

        // Edit and Delete end the first row: two buttons' words, apart.
        let buttons = runs(inked(card, rows: header, columns: inside(card, from: card.width / 2)))
        #expect(buttons.count == 2, "Edit, then Delete: \(buttons)")
        #expect((buttons.last?.upperBound ?? 0) > card.width - pixel(PRStyle.inset * 2 + 4), "at the card's far edge")

        // The words written on github.com, under that row.
        let under = rows(header.upperBound, card.height - pixel(PRStyle.inset))
        #expect(inkedRows(card, rows: under) >= pixel(6), "the comment's words")

        #if os(iOS)
            // The mark leads the row in the waiting tone. The tones are the host's colour sets: clear under `swift test`.
            let tone = Pixel(Color.toneWaiting.resolve(in: environment))
            let marked = (0 ..< card.width / 2).count { column in
                header.contains { card[column, $0].distance(to: tone) <= 24 }
            }
            #expect(marked >= pixel(10), "Pending, in the waiting tone: \(marked) columns of it")
        #endif
    }

    /// A card whose words are being changed is its box: Edit and Delete are not offered over it.
    @Test func aCardWhoseWordsAreBeingChangedOffersNoEditOrDelete() throws {
        let session = try SamplePR.session()
        let comment = try #require(session.pending.first)
        session.editText(for: comment).wrappedValue = comment.body
        // No picture is kept: `ImageRenderer` draws no field, so the box is not as the screen shows it.
        let open = try render(nil, PRPendingCard(comment: comment, actions: PRPendingActions(session)), in: .light)
        #expect(inked(open, rows: header, columns: inside(open, from: open.width / 2)).isEmpty, "no Edit, no Delete")
    }

    // MARK: - The one GitHub refused

    @Test(arguments: [ColorScheme.light, .dark])
    func aRefusedCommentSaysWhyAndOffersTryAgainAndItsFile(_ scheme: ColorScheme) throws {
        let refusal = "GitHub didn't take the comment. Its line may no longer be in the diff."
        let taken = try render(nil, PRPendingCard(comment: SamplePR.device(), actions: .none), in: scheme)
        let refused = try render(
            "refused", PRPendingCard(comment: SamplePR.device(failure: refusal), actions: .none), in: scheme
        )
        // GitHub's reason and a row of buttons under the words.
        let grown = refused.height - taken.height
        #expect(grown >= pixel(PRStyle.controlHeight + Space.sm * 2 + 10), "the reason and its buttons: \(grown) px")

        let buttons = runs(inked(refused, rows: foot(refused), columns: inside(refused)))
        #expect(buttons.count == 2, "Try again, and Add to the file instead: \(buttons)")

        // One already on its file has no file left to go to.
        let onFile = try render(
            "refused-on-file",
            PRPendingCard(comment: SamplePR.device(failure: refusal, isFile: true), actions: .none), in: scheme
        )
        #expect(runs(inked(onFile, rows: foot(onFile), columns: inside(onFile))).count == 1, "Try again alone")

        // GitHub's own comment whose change was refused: no file to go to either.
        let github = try render(
            "refused-change", PRPendingCard(comment: SamplePR.onLine(sync: .failed(refusal)), actions: .none),
            in: scheme
        )
        #expect(runs(inked(github, rows: foot(github), columns: inside(github))).count == 1)
    }

    // MARK: - The PR's page

    /// The page's list: a heading, then each comment's card saying where it belongs, as no line of code is over it.
    @Test(arguments: [ColorScheme.light, .dark])
    func thePagesListHeadsTheCardsOfCommentsWithNoLineEachWithItsPlace(_ scheme: ColorScheme) throws {
        let session = try SamplePR.session()
        let offDiff = try #require(session.pendingOffDiff.first)
        let list = try render("page-list", PRPendingList(session: session).background(Color.groundCard), in: scheme)
        let placed = try render(nil, PRPendingCard(comment: offDiff, actions: .none, showsLocation: true), in: scheme)
        let bare = try render(nil, PRPendingCard(comment: offDiff, actions: .none), in: scheme)

        // Where it belongs is written in the card's first row, between its mark and Edit.
        let middle = pixel(PRStyle.inset + 72) ..< Int(Self.width * Self.scale) / 2
        #expect(inked(placed, rows: header, columns: middle).count >= pixel(40), "the file's path")
        #expect(inked(bare, rows: header, columns: middle).isEmpty, "under its line a card says no place")

        // The list is a heading over that card: the same card, lower by the heading.
        let heading = list.height - placed.height
        #expect(heading >= pixel(Space.sm + 10), "a heading over the card: \(heading) px")
        #expect(inkedRows(list, rows: rows(0, heading - pixel(Space.sm))) >= pixel(6), "with its words")
        let listed = inked(list, rows: rows(heading + header.lowerBound, heading + header.upperBound), columns: middle)
        #expect(abs(listed.count - inked(placed, rows: header, columns: middle).count) <= 2, "its card says its place")
    }

    // MARK: - The count over the review's buttons

    /// The review's buttons with the line over them that says what goes with the review, and without it where
    /// nothing is pending.
    @Test(arguments: [ColorScheme.light, .dark])
    func theReviewsButtonsSayWhatGoesWithItOnlyWhereSomethingIsPending(_ scheme: ColorScheme) throws {
        let pending = try SamplePR.session()
        let none = try SamplePR.session(pending: false)
        #expect(pending.pendingGoing == 2 && none.pendingGoing == 0)
        let with = try render(
            "count", PRReviewActions(session: pending, isAuthor: false, action: .constant(nil)).background(Color.groundCard),
            in: scheme
        )
        let without = try render(
            nil, PRReviewActions(session: none, isAuthor: false, action: .constant(nil)).background(Color.groundCard),
            in: scheme
        )
        let line = with.height - without.height
        #expect(line >= pixel(Space.sm + 10), "a line of words over the buttons: \(line) px")
        #if os(iOS)
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let tone = Pixel(Color.toneWaiting.resolve(in: environment))
            let toned = rows(0, line).count { row in (0 ..< with.width).contains { with[$0, row].distance(to: tone) <= 24 } }
            #expect(toned >= pixel(5), "in the waiting tone: \(toned) rows of it")
        #endif
    }
}

/// The sample PR acme/web#412 as these tests need it: its diff of two files, and the review begun on github.com with
/// one comment on a line of `payments.ts` and one on the whole of `CheckoutError.tsx`.
@MainActor
enum SamplePR {
    static let path = "src/checkout/payments.ts"
    static let filePath = "src/checkout/CheckoutError.tsx"
    static let onLineID = "sample-pending-412-1"
    static let onFileID = "sample-pending-412-2"

    static let diff = """
    diff --git a/src/checkout/CheckoutError.tsx b/src/checkout/CheckoutError.tsx
    --- a/src/checkout/CheckoutError.tsx
    +++ b/src/checkout/CheckoutError.tsx
    @@ -1,5 +1,17 @@
     import { useState } from "react";
    +import { retryPayment } from "./payments";
     // Shown when the payment step fails.
     export function CheckoutError({ order }) {
    -  return <p>Payment failed. Please try again later.</p>;
    +  const [retrying, setRetrying] = useState(false);
    +  const retry = async () => {
    +    setRetrying(true);
    +    await retryPayment(order.id);
    +    setRetrying(false);
    +  };
    +  return (
    +    <div role="alert">
    +      <p>Payment failed.</p>
    +      <button onClick={retry} disabled={retrying}>Try again</button>
    +    </div>
    +  );
     }
    diff --git a/src/checkout/payments.ts b/src/checkout/payments.ts
    --- a/src/checkout/payments.ts
    +++ b/src/checkout/payments.ts
    @@ -10,2 +10,6 @@ export async function pay(order) {
       return api.post(`/orders/${order.id}/pay`);
     }
    +// The server ignores a second payment for the same order.
    +export async function retryPayment(orderId) {
    +  return api.post(`/orders/${orderId}/pay`, { retry: true });
    +}

    """

    private static let review = """
    {"id": "sample-pending-412", "body": "", "comments": [
      {"id": "\(onLineID)", "path": "\(path)", "line": 13, "side": "RIGHT",
       "body": "Should a retry stop after a few tries?", "createdAt": "2026-11-26T08:00:00Z",
       "outdated": false, "thread": null, "file": false},
      {"id": "\(onFileID)", "path": "\(filePath)", "line": null, "side": "RIGHT",
       "body": "This file could use a test for the retry.", "createdAt": "2026-11-26T09:00:00Z",
       "outdated": false, "thread": null, "file": true}]}
    """

    private static func detail(pendingReview: String) -> String {
        """
        {"url": "u", "head": "h", "base": "main", "headBranch": "retry-checkout",
         "author": {"login": "mona", "avatarUrl": null}, "isAuthor": false, "body": "", "additions": 16, "deletions": 1,
         "changedFiles": 2, "reviewDecision": null, "mergeState": "CLEAN", "labels": [{"name": "sample", "color": "8250DF"}],
         "checks": [], "comments": {"nodes": []}, "reviews": {"nodes": []}, "reviewThreads": {"nodes": []},
         "pendingReview": \(pendingReview), "title": "Show a retry button when checkout fails"}
        """
    }

    /// The sample's comment on line 13 of `payments.ts`, as GitHub holds it.
    static var onLine: PRPendingComment {
        onLine(sync: .synced)
    }

    static func onLine(sync: PRPendingComment.Sync) -> PRPendingComment {
        PRPendingComment(
            origin: .github(onLineID), path: path, line: 13, side: .right, body: "Should a retry stop after a few tries?",
            sync: sync
        )
    }

    /// A comment written on this device on line 12; `failure` set, GitHub refused it in those words.
    static func device(failure: String? = nil, isFile: Bool? = nil) -> PRPendingComment {
        PRPendingComment(PRDraftComment(
            id: UUID(uuidString: "7B0E8D6C-3C1B-4C55-9B62-0C1D0E5B7A11") ?? UUID(), path: path, line: 12, side: .right,
            body: "Sample kiwi comment", isFile: isFile, sync: failure.map { PRDraftSync(failure: $0) }
        ))
    }

    /// The sample PR's session, answered on the phone: with its review begun on github.com, or with none.
    static func session(pending: Bool = true, labels: PRRepoLabels? = nil) throws -> PRSession {
        let row = PullRequestRow(
            repo: "acme/web", number: 412, title: "Show a retry button when checkout fails", head: "h",
            revision: "sample", diff: .ready, detail: "sample", status: nil
        )
        var samples = PRSampleSet(
            samples: [.init(row: row, detail: detail(pendingReview: pending ? review : "null"), diff: diff, keyLines: nil)],
            mergedReviewed: [], mergedMine: [], answersOnPhone: true
        )
        if let labels {
            samples.repoLabels = labels
        }
        let client = PRViewerClient(access: .offline, transport: NoRequest())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let session = model.session(for: row)
        try #require(session.content != nil, "the sample PR is read from the phone")
        return session
    }

    /// Keeps `image` as the test's picture, `<name>.png`.
    static func keep(_ image: CGImage, named name: String) throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination), "the picture is a PNG")
        Attachment.record(data as Data, named: "\(name).png")
    }

    private struct NoRequest: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            Issue.record("Unexpected rendering request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            throw URLError(.unsupportedURL)
        }
    }
}
