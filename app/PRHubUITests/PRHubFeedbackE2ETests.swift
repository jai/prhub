import XCTest

/// End to end (issue #51): a message from the Feedback tab reaches FeedbackKit's live Worker as its test app, and the
/// runner's answer, `echo: <the message>`, comes back into the chat. The answer comes only once the runner has
/// delivered the message, so it proves both. Needs the Worker's root and a token signed with the test app's key, as
/// `TEST_RUNNER_FEEDBACKKIT_E2E_URL` and `TEST_RUNNER_FEEDBACKKIT_E2E_TOKEN` (the e2e workflow's `feedback-ui` job,
/// which also deletes the test app's chats before and after); skipped without them. The tab is on FeedbackKit's direct
/// path, as PRHub's own is when its Worker names one (issue #53).
@MainActor
final class PRHubFeedbackE2ETests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    private var values: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Launches on the Feedback tab, on FeedbackKit's direct path; skipped without the URL and token.
    private func launchOnTheLiveWorker() throws {
        let url = values["FEEDBACKKIT_E2E_URL"] ?? ""
        let token = values["FEEDBACKKIT_E2E_TOKEN"] ?? ""
        try XCTSkipIf(
            url.isEmpty || token.isEmpty,
            "an end-to-end run only: needs FEEDBACKKIT_E2E_URL and FEEDBACKKIT_E2E_TOKEN (the e2e workflow sets both)"
        )
        app.launchArguments = ["-PRHubFeedbackE2E"]
        app.launchEnvironment = ["FEEDBACKKIT_E2E_URL": url, "FEEDBACKKIT_E2E_TOKEN": token]
        app.launch()
    }

    func testAMessageFromTheFeedbackTabComesBackAsTheRunnersEcho() throws {
        try launchOnTheLiveWorker()
        let new = app.buttons["feedback-new"]
        XCTAssertTrue(new.waitForExistence(timeout: 20), "the Feedback tab, read from the live Worker")
        new.tap()
        let text = "End-to-end check \(UUID().uuidString.prefix(8))"
        let field = app.textViews["sessionReplyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        app.buttons["sessionReplySend"].tap()

        let echo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "echo: \(text)")).firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 90), "the runner's echo, after it delivered the message")
        keep("feedback-e2e-echo")
    }

    /// A chat whose first message carries a screenshot (the workflow sends it before this test, as
    /// `FEEDBACKKIT_E2E_SCREENSHOT_TEXT`): the screenshot shows in that message, and a tap opens it (issue #53).
    func testASentScreenshotShowsInItsMessageAndOpens() throws {
        let seeded = values["FEEDBACKKIT_E2E_SCREENSHOT_TEXT"] ?? ""
        try XCTSkipIf(seeded.isEmpty, "an end-to-end run only: the e2e workflow sends the screenshot first")
        try launchOnTheLiveWorker()

        // The row's title is a text inside its button, which has no label of its own (FeedbackKit 0.5).
        let row = app.descendants(matching: .any).matching(identifier: "feedback-thread")
            .containing(NSPredicate(format: "label BEGINSWITH %@", seeded)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the chat with the screenshot")
        row.tap()
        let thumbnail = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feedback-screenshot-'")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 30), "the screenshot, in the message that sent it")
        keep("feedback-e2e-screenshot")
        thumbnail.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sent-screenshot-viewer"].waitForExistence(timeout: 10),
                      "the screenshot, opened")
        keep("feedback-e2e-screenshot-open")
    }

    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
