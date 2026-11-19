import XCTest

/// A PR's page over the sample PRs, where only a screen shows it: the review box above the keyboard, Open in GitHub's
/// menu, and Ask's long answer across the chat. What the page decides is `PRHubScreenTests`'. Pictures go to
/// `SCREENSHOTS_DIR` when it is set.
@MainActor
final class PRHubPRPageUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
    }

    /// The bug bash's keyboard bug (2026-11-10): six lines in the review's box with the keyboard up, and the button
    /// that sends it still shows above the keys. This check requires the software keyboard.
    func testAReviewsSendButtonStaysAboveTheKeyboard() throws {
        launch([])
        openCheckout()
        let request = app.buttons["pr-review-request-changes"]
        for _ in 0 ..< 5 where !(request.exists && request.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        request.tap()
        let field = app.descendants(matching: .any)["inline-composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("line one\nline two\nline three\nline four\nline five\nline six")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the software keyboard must be visible for this layout check")
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(waitFor { send.exists && send.isHittable && send.frame.maxY <= keyboard.frame.minY },
                      "the send button remains above the software keyboard")
        try picture("review-box-keyboard-up")
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY, "the send button overlaps the keyboard")
    }

    /// A long press on Open in GitHub offers the PR's link, to copy or to share.
    func testALongPressOnOpenInGitHubOffersThePRsLink() throws {
        launch([])
        openCheckout()
        let open = app.descendants(matching: .any)["open-in-github"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["pr-link-copy"].waitForExistence(timeout: 5))
        try picture("open-in-github-menu")
        app.buttons["pr-link-copy"].tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5), "still on the PR, not in a browser")
    }

    /// An agent's long answer takes most of the chat's width from its leading edge, so its words don't break mid-word
    /// (UI bug 015, seen on a Mac; `AskSheetWidthTests` pictures the sheet there).
    func testALongAnswerTakesTheChatsWidth() throws {
        launch(["-PRHubAskAnswered"])
        openCheckout()
        app.buttons["pr-ask"].tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'recovery screen'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["sessionReplyField"].firstMatch
        // The chat's width: from the reply box's leading edge to the send button's trailing one.
        let width = app.buttons["sessionReplySend"].frame.maxX - field.frame.minX
        try picture("ask-long-answer")
        XCTAssertGreaterThan(
            answer.frame.width, width * 0.6, "the answer is \(Int(answer.frame.width)) pt of \(Int(width))"
        )
        XCTAssertLessThan(
            answer.frame.minX - field.frame.minX, width * 0.1, "the answer starts at the chat's leading edge"
        )
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = []) {
        app.terminate()
        app.launchArguments = ["-PRHubPaired"] + arguments
        app.launch()
    }

    private func openCheckout() {
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
    }

    private func picture(_ name: String) throws {
        try recordScreenshot("\(name)-light")
    }
}
