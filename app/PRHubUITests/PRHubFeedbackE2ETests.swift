import XCTest

/// End to end (issue #51): a message from the Feedback tab reaches FeedbackKit's live Worker as its test app, and the
/// runner's answer, `echo: <the message>`, comes back into the chat. The answer comes only once the runner has
/// delivered the message, so it proves both. Needs the Worker's root and a token signed with the test app's key, as
/// `TEST_RUNNER_FEEDBACKKIT_E2E_URL` and `TEST_RUNNER_FEEDBACKKIT_E2E_TOKEN` (the e2e workflow's `feedback-ui` job,
/// which also deletes the test app's chats before and after); skipped without them.
@MainActor
final class PRHubFeedbackE2ETests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testAMessageFromTheFeedbackTabComesBackAsTheRunnersEcho() throws {
        let values = ProcessInfo.processInfo.environment
        let url = values["FEEDBACKKIT_E2E_URL"] ?? ""
        let token = values["FEEDBACKKIT_E2E_TOKEN"] ?? ""
        try XCTSkipIf(
            url.isEmpty || token.isEmpty,
            "an end-to-end run only: needs FEEDBACKKIT_E2E_URL and FEEDBACKKIT_E2E_TOKEN (the e2e workflow sets both)"
        )
        app.launchArguments = ["-PRHubFeedbackE2E"]
        app.launchEnvironment = ["FEEDBACKKIT_E2E_URL": url, "FEEDBACKKIT_E2E_TOKEN": token]
        app.launch()

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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "feedback-e2e-echo"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
