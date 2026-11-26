import XCTest

/// The review not submitted yet, over the sample PR that comes with one begun on github.com (acme/web#412: a comment on
/// `src/checkout/payments.ts` line 13 and one on the whole of `src/checkout/CheckoutError.tsx`). Its comments show
/// under their lines in the diff and, with no line there, in a list on the PR's page; each is changed and deleted on
/// its card; a new one joins the same review; one GitHub refuses says why and can go on its file instead. What the
/// list holds and what is sent is `PRPendingSyncTests`'. One launch a test. Pictures stay in the test's result bundle.
@MainActor
final class PRKitPendingReviewUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"
    private let onLine = "Should a retry stop after a few tries?"
    private let onFile = "This file could use a test for the retry."
    /// The diff's row for `payments.ts` line 12, the added comment line over the one the sample's comment is on: a
    /// new comment goes here. Its number is its line's place in the whole diff.
    private let lineToCommentOn = "diff-line-28"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - a. What GitHub's pending review shows

    func testTheDiffShowsGitHubsPendingCommentUnderItsLine() {
        diffShowsThePendingComment(.light)
    }

    func testTheDiffShowsGitHubsPendingCommentUnderItsLineInTheDark() {
        diffShowsThePendingComment(.dark)
    }

    private func diffShowsThePendingComment(_ appearance: XCUIDevice.Appearance) {
        launch(appearance: appearance)
        openDiffAtThePendingComment()
        XCTAssertTrue(element("pending-comment").exists, "the comment's card")
        XCTAssertTrue(app.staticTexts["Pending"].firstMatch.exists, "marked Pending")
        XCTAssertTrue(words(onLine).exists, "with the words written on github.com")
        XCTAssertTrue(app.buttons["pending-edit"].firstMatch.exists, "Edit")
        XCTAssertTrue(app.buttons["pending-delete"].firstMatch.exists, "Delete")
        XCTAssertFalse(words(onFile).exists, "the comment on a whole file has no line here")
        recordScreenshot("pending-diff-\(appearance == .dark ? "dark" : "light")")
    }

    func testTheReviewSaysBothPendingCommentsGoWithIt() {
        launch()
        app.openPR(checkout)
        XCTAssertEqual(pendingCount(), "2 pending comments will go with your review", "GitHub's count")
        let comment = app.buttons["pr-review-comment"]
        XCTAssertTrue(app.reveal(comment))
        comment.tap()
        XCTAssertTrue(app.buttons["inline-composer-send"].waitForExistence(timeout: 5), "the review's box")
        XCTAssertEqual(pendingCount(), "2 pending comments will go with your review", "still said with the box open")
        recordScreenshot("pending-review-box")
    }

    // MARK: - b. Add

    func testACommentOnALineIsAddedToTheOneReview() {
        launch()
        openDiffAtThePendingComment()
        openLineBox()
        let send = app.buttons["inline-composer-send"]
        XCTAssertEqual(send.label, "Add to review")
        XCTAssertFalse(app.buttons["Start review"].exists, "there is always one review to add to")
        recordScreenshot("pending-add-box")
        type("Sample kiwi comment", into: field)
        XCTAssertEqual(send.label, "Add to review", "the same words with something typed")
        send.tap()
        XCTAssertTrue(words("Sample kiwi comment").waitForExistence(timeout: 5), "the new comment, under its line")
        XCTAssertTrue(waitFor { self.app.buttons.matching(identifier: "pending-edit").count == 2 }, "a card of its own")
        recordScreenshot("pending-added")

        // The button reads the same with the review one comment longer.
        openLineBox()
        XCTAssertEqual(app.buttons["inline-composer-send"].label, "Add to review")
        XCTAssertFalse(app.buttons["Start review"].exists)
        app.buttons["Cancel"].firstMatch.tap()

        backToThePR()
        XCTAssertEqual(pendingCount(), "3 pending comments will go with your review")
        recordScreenshot("pending-added-count")
    }

    // MARK: - c. Edit

    func testAPendingCommentsWordsAreChangedOnItsCard() {
        launch()
        openDiffAtThePendingComment()
        app.buttons["pending-edit"].firstMatch.tap()
        let save = app.buttons["inline-composer-send"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the card's own box")
        XCTAssertEqual(save.label, "Save")
        type(" kiwi ", into: field)
        recordScreenshot("pending-edit-box")
        save.tap()
        XCTAssertTrue(words("kiwi").waitForExistence(timeout: 5), "the card shows the new words")
        XCTAssertTrue(waitFor { self.app.buttons["pending-edit"].firstMatch.exists }, "the box has closed")
        XCTAssertTrue(app.staticTexts["Pending"].firstMatch.exists, "still Pending")
        recordScreenshot("pending-edited")
    }

    // MARK: - d. Delete

    func testADeletedPendingCommentGoesAndTheCountDrops() {
        launch()
        openDiffAtThePendingComment()
        app.buttons["pending-delete"].firstMatch.tap()
        XCTAssertTrue(waitFor { !self.words(self.onLine).exists }, "the card goes")
        XCTAssertFalse(app.buttons["pending-edit"].exists)
        recordScreenshot("pending-deleted")
        backToThePR()
        XCTAssertEqual(pendingCount(), "1 pending comment will go with your review")
        recordScreenshot("pending-deleted-count")
    }

    // MARK: - e. The PR's page

    func testThePRsPageListsThePendingCommentWithNoLineInTheDiff() {
        launch()
        app.openPR(checkout)
        let edit = app.buttons["pending-edit"].firstMatch
        XCTAssertTrue(app.reveal(edit), "the list, under the review's buttons")
        XCTAssertTrue(element("pr-pending-list").exists)
        XCTAssertTrue(app.staticTexts["Pending comments · 1"].exists, "one: the other sits under its line in the diff")
        XCTAssertTrue(words(onFile).exists, "the comment on the whole file")
        XCTAssertTrue(app.staticTexts["src/checkout/CheckoutError.tsx"].exists, "with its file's path")
        XCTAssertFalse(words(onLine).exists)
        XCTAssertTrue(app.buttons["pending-delete"].firstMatch.exists)
        recordScreenshot("pending-page-list")
    }

    // MARK: - f. A comment GitHub refuses

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
        recordScreenshot("pending-refused")

        toFile.tap()
        XCTAssertTrue(waitFor { !self.app.buttons["pending-add-to-file"].exists }, "it leaves its line")
        XCTAssertFalse(app.staticTexts["pending-failure"].exists)
        backToThePR()
        XCTAssertEqual(pendingCount(), "3 pending comments will go with your review")
        let moved = words("Line 12: Sample kiwi comment")
        XCTAssertTrue(app.reveal(moved), "it joins the page's list, saying which line it was written on")
        XCTAssertTrue(app.staticTexts["Pending comments · 2"].exists)
        recordScreenshot("pending-refused-on-file")
    }

    /// The refusal grows the card downwards, GitHub's reason and two buttons: the diff brings it whole above the key
    /// line stepper and the panel button that float over its foot.
    func testARefusedCommentsButtonsAreClearOfTheFloatingControls() {
        launch(["-PRHubPendingAddRefused"])
        openDiffAtThePendingComment()
        openLineBox()
        type("Sample kiwi comment", into: field)
        app.buttons["inline-composer-send"].tap()
        let toFile = app.buttons["pending-add-to-file"].firstMatch
        let retry = app.buttons["pending-retry"].firstMatch
        XCTAssertTrue(toFile.waitForExistence(timeout: 5), "Add to the file instead")
        let stepper = app.buttons["key-line-position"]
        let panel = app.buttons["diff-files"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "the floating controls are back once the box has gone")
        let isClear = { (button: XCUIElement) in
            button.isHittable && !button.frame.intersects(stepper.frame) && !button.frame.intersects(panel.frame)
        }
        XCTAssertTrue(waitFor { isClear(toFile) && isClear(retry) }, "the card is brought above the controls")
        app.waitForStill(toFile)
        XCTAssertTrue(toFile.isHittable && retry.isHittable, "both take a tap")
        for button in [toFile, retry] {
            XCTAssertFalse(button.frame.intersects(stepper.frame), "\(button.label) is clear of the stepper")
            XCTAssertFalse(button.frame.intersects(panel.frame), "\(button.label) is clear of the panel button")
        }
        recordScreenshot("pending-refused-clear")
    }

    // MARK: - Steps

    private func launch(_ arguments: [String] = [], appearance: XCUIDevice.Appearance = .light) {
        app.launch(["-PRHubPaired", "-prhubAlertsDeclined", "YES"] + arguments, appearance: appearance)
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

    /// A tap on the line over the sample's comment opens the line's box.
    private func openLineBox() {
        let line = app.cells[lineToCommentOn]
        XCTAssertTrue(line.exists && line.isHittable, "the line to comment on")
        line.tap()
        XCTAssertTrue(app.buttons["inline-composer-send"].waitForExistence(timeout: 5), "the line's box")
    }

    /// Back from the diff to the PR's page, its top in view.
    private func backToThePR() {
        app.back()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5), "the PR's page")
    }
}
