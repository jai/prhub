import XCTest

/// The review not submitted yet, over the sample PR that comes with one begun on github.com (acme/web#412: a comment on
/// `src/checkout/payments.ts` line 13 and one on the whole of `src/checkout/CheckoutError.tsx`), as far as it needs a
/// real screen: a comment typed on a line, a card's words changed and a card deleted, each read back on the PR's
/// page, and one GitHub refuses moved to its file. Two launches.
///
/// What needs no running app is proven below this: how a card, the page's list and the count line are drawn, in light
/// and dark, with their pictures (`PRPendingCardRenderingTests`); the card under its line in the diff's table, and
/// a refused one brought clear of the floating controls (`DiffPendingRowTests`, `PRPendingRevealTests`); what the list
/// and the count hold (`PRPendingPageTests`, `PRPendingListTests`); what is sent (`PRPendingSyncTests`).
@MainActor
final class PRKitPendingReviewUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"
    private let onLine = "Should a retry stop after a few tries?"
    /// The diff's row for `payments.ts` line 12, the added comment line over the one the sample's comment is on: a
    /// new comment goes here. Its number is its line's place in the whole diff.
    private let lineToCommentOn = "diff-line-28"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - a. Changed, added and deleted with the keyboard, then counted on the PR's page

    func testAPendingCommentIsChangedOneIsAddedAndBothAreDeleted() {
        launch()
        openDiffAtThePendingComment()
        XCTAssertTrue(element("pending-comment").exists, "the comment begun on github.com, under its line")
        XCTAssertTrue(app.staticTexts["Pending"].firstMatch.exists, "marked Pending")
        XCTAssertTrue(words(onLine).exists, "with its words")

        // Its words are changed in the card's own box.
        app.buttons["pending-edit"].firstMatch.tap()
        let save = app.buttons["inline-composer-send"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the card's own box")
        XCTAssertEqual(save.label, "Save")
        type(" mango ", into: field)
        save.tap()
        XCTAssertTrue(words("mango").waitForExistence(timeout: 5), "the card shows the new words")
        let edit = app.buttons["pending-edit"].firstMatch
        XCTAssertTrue(waitFor { edit.exists && edit.isHittable }, "the box has closed")
        XCTAssertTrue(app.staticTexts["Pending"].firstMatch.exists, "still Pending")
        app.waitForStill(edit)

        // A comment typed on the line over it joins the same review.
        openLineBox()
        let send = app.buttons["inline-composer-send"]
        XCTAssertEqual(send.label, "Add to review")
        XCTAssertFalse(app.buttons["Start review"].exists, "there is always one review to add to")
        type("Sample kiwi comment", into: field)
        XCTAssertEqual(send.label, "Add to review", "the same words with something typed")
        send.tap()
        XCTAssertTrue(words("Sample kiwi comment").waitForExistence(timeout: 5), "the new comment, under its line")
        let cards = app.buttons.matching(identifier: "pending-edit")
        XCTAssertTrue(waitFor { cards.count == 2 }, "a card of its own")

        // Each card's Delete takes its comment away.
        let delete = app.buttons["pending-delete"].firstMatch
        XCTAssertTrue(waitFor { delete.exists && delete.isHittable }, "Delete, on the first card")
        delete.tap()
        XCTAssertTrue(waitFor { cards.count == 1 }, "one card goes")
        XCTAssertTrue(waitFor { delete.exists && delete.isHittable }, "Delete, on the card that is left")
        app.waitForStill(delete)
        delete.tap()
        XCTAssertTrue(waitFor { !self.app.buttons["pending-edit"].exists }, "and the other")
        XCTAssertFalse(words("Sample kiwi comment").exists)
        XCTAssertFalse(words("mango").exists)

        // The PR's page counts what is left: the comment on the whole file.
        backToThePR()
        XCTAssertEqual(pendingCount(), "1 pending comment will go with your review")
    }

    // MARK: - b. A comment GitHub refuses

    func testARefusedCommentSaysWhyAndCanGoOnItsFileInstead() {
        launch(["-PRHubPendingAddRefused"])
        openDiffAtThePendingComment()
        openLineBox()
        type("Sample kiwi comment", into: field)
        app.buttons["inline-composer-send"].tap()
        let toFile = app.buttons["pending-add-to-file"].firstMatch
        XCTAssertTrue(toFile.waitForExistence(timeout: 5), "Add to the file instead")
        XCTAssertEqual(toFile.label, "Add to the file instead")
        XCTAssertEqual(app.buttons["pending-retry"].firstMatch.label, "Try again")
        let reason = app.staticTexts["pending-failure"].firstMatch
        XCTAssertTrue(reason.exists, "GitHub's reason, on the card")
        XCTAssertTrue(reason.label.contains("may no longer be in the diff"), reason.label)
        XCTAssertTrue(words("Sample kiwi comment").exists, "the words are kept")

        XCTAssertTrue(waitFor { toFile.isHittable }, "the card's buttons are brought clear of the floating controls")
        app.waitForStill(toFile)
        toFile.tap()
        XCTAssertTrue(waitFor { !self.app.buttons["pending-add-to-file"].exists }, "it leaves its line")
        XCTAssertFalse(app.staticTexts["pending-failure"].exists)
        backToThePR()
        XCTAssertEqual(pendingCount(), "3 pending comments will go with your review")
        let moved = words("Line 12: Sample kiwi comment")
        XCTAssertTrue(app.reveal(moved), "it joins the page's list, saying which line it was written on")
        XCTAssertTrue(element("pr-pending-list").exists)
        XCTAssertTrue(app.staticTexts["Pending comments · 2"].exists)
    }

    // MARK: - Steps

    private func launch(_ arguments: [String] = []) {
        app.launch(["-PRHubPaired", "-prhubAlertsDeclined", "YES"] + arguments, appearance: .light)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private var field: XCUIElement {
        element("inline-composer-field")
    }

    /// Words someone wrote, wherever Markdown draws them.
    private func words(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The line over the review's buttons that says what goes with the review.
    private func pendingCount() -> String {
        let line = app.staticTexts["pr-pending-comments"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "what goes with the review")
        return line.label
    }

    private var diffTable: XCUIElement {
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        return app.tables.containing(.cell, identifier: lines.firstMatch.identifier).firstMatch
    }

    /// The PR's diff, read down until the sample's pending comment and the line over it can be tapped.
    private func openDiffAtThePendingComment() {
        app.openPR(checkout)
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(app.reveal(files), "Files changed, on the PR's page")
        files.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 10), "the diff")
        let edit = app.buttons["pending-edit"].firstMatch
        let line = app.cells[lineToCommentOn]
        let table = diffTable
        // `while`, not `for … where`: it stops asking at the first yes.
        var swipes = 0
        while swipes < 8, !(edit.exists && edit.isHittable && line.exists && line.isHittable) {
            table.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(edit.exists && edit.isHittable, "the pending comment, under its line")
        app.waitForStill(edit)
    }

    /// A tap on the line over the sample's comment opens the line's box. A box that closed can leave the line just
    /// over the top of what shows: a short drag down brings it back.
    private func openLineBox() {
        let line = app.cells[lineToCommentOn]
        let table = diffTable
        var drags = 0
        while drags < 4, !(line.exists && line.isHittable) {
            let from = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 120)))
            drags += 1
        }
        XCTAssertTrue(line.exists && line.isHittable, "the line to comment on")
        line.tap()
        XCTAssertTrue(app.buttons["inline-composer-send"].waitForExistence(timeout: 5), "the line's box")
    }

    /// Back from the diff to the PR's page, its top in view.
    private func backToThePR() {
        // Reading down the diff hides its bars; a short drag the other way brings them, and Back, again.
        if !app.navigationBars.firstMatch.exists {
            diffTable.swipeDown(velocity: .slow)
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "the bar, after a drag down")
        }
        app.back()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5), "the PR's page")
    }
}
