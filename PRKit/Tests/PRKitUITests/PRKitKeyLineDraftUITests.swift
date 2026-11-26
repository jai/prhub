import XCTest

/// A key line's words into the review, over the sample PR acme/web#412, whose first key line is a risk on
/// `src/checkout/CheckoutError.tsx` line 9. Its row in the panel and its note under the line each have Copy and Add to
/// review; the press opens the line's comment box with the key line's words in it, the box's own Add to review keeps
/// them as a pending comment, and the control is then ticked and adds no second. What is kept and where is
/// `PRKeyLineDraftTests`'. One launch a test. Pictures stay in the test's result bundle.
@MainActor
final class PRKitKeyLineDraftUITests: PRHubUITestCase {
    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"
    private let line = "src/checkout/CheckoutError.tsx:RIGHT:9"
    private let why = "If retryPayment throws, retrying stays true and the button stays disabled."

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    func testAKeyLinesWordsAreAddedToTheReviewFromItsNoteOnce() {
        openPanel()
        let rowAdd = app.buttons["key-line-add-\(line)"]
        XCTAssertTrue(rowAdd.exists && rowAdd.isHittable, "Add to review, on the key line's row")
        XCTAssertEqual(rowAdd.value as? String, "not added")
        XCTAssertTrue(app.buttons["key-line-copy-\(line)"].isHittable, "Copy, on the key line's row")
        recordScreenshot("key-line-row")

        app.buttons["key-line-\(line)"].tap()
        let add = app.buttons["key-line-note-add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add to review, on the note under the line")
        app.waitForStill(add)
        XCTAssertTrue(app.buttons["key-line-note-copy"].firstMatch.exists, "Copy, on the note")
        XCTAssertEqual(add.value as? String, "not added")
        recordScreenshot("key-line-note")

        add.tap()
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the line's comment box")
        let field = app.descendants(matching: .any)["inline-composer-field"].firstMatch
        XCTAssertEqual(field.value as? String, why, "with the key line's words in it, to be changed")
        XCTAssertEqual(send.label, "Add to review")
        XCTAssertEqual(add.value as? String, "not added", "nothing is kept yet")
        recordScreenshot("key-line-box-prefilled")

        send.tap()
        // The tick is read from the review's pending comments: it says the comment is kept.
        XCTAssertTrue(waitFor { add.exists && add.value as? String == "added" }, "kept, and the note's control is ticked")
        XCTAssertTrue(app.staticTexts["Pending"].firstMatch.exists, "its card, marked Pending")
        XCTAssertEqual(add.label, "Add to review", "and reads the same")
        recordScreenshot("key-line-added")

        // A second press shows the comment there is, and opens no second box.
        app.waitForStill(add)
        add.tap()
        XCTAssertFalse(app.buttons["inline-composer-send"].waitForExistence(timeout: 2), "no second box")
        XCTAssertEqual(add.value as? String, "added")
    }

    func testTheRowsControlsFitInTheLargestText() {
        openPanel(textSize: Self.largest)
        let window = app.windows.firstMatch.frame
        for name in ["key-line-copy-\(line)", "key-line-add-\(line)", "key-line-explain-\(line)"] {
            let control = app.buttons[name]
            XCTAssertTrue(control.exists && control.isHittable, name)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX, "\(name) is on the card")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(name) is a finger's width")
        }
        XCTAssertFalse(
            app.buttons["key-line-add-\(line)"].frame.intersects(app.buttons["key-line-reviewed-\(line)"].frame),
            "clear of the tick"
        )
        recordScreenshot("key-line-row-largest")
    }

    /// The checkout sample's diff, its panel open on Key lines.
    private func openPanel(textSize: String? = nil) {
        app.launch(
            ["-PRHubPaired", "-prhubAlertsDeclined", "YES"]
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: .light
        )
        app.openPR("Show a retry button when checkout fails")
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(app.reveal(review), "Review changes, on the PR's page")
        review.tap()
        XCTAssertTrue(app.buttons["key-line-\(line)"].waitForExistence(timeout: 10), "the panel open on Key lines")
        app.waitForStill(app.buttons["key-line-\(line)"])
    }
}
