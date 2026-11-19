import XCTest

/// A PR's page over the sample PRs, where only a screen shows it: the review box above the keyboard, and Open in GitHub's
/// menu. What the page decides is `PRScreenModelTests`'; Ask's width is `PresentedWidthTests`'. Pictures stay in the
/// test's result bundle.
@MainActor
final class PRKitPRPageUITests: PRHubUITestCase {
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
        recordScreenshot("\(name)-light")
    }
}
