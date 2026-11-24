import XCTest

/// The Feedback tab, where the Worker serves it: the list of chats, and a tapped push of a feedback chat (FeedbackKit's
/// own, which PRHub registers the phone for) opening Feedback on that chat.
@MainActor
final class PRHubFeedbackUITests: PRHubUITestCase {
    private func text(containing words: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", words)).firstMatch
    }

    func testTheFeedbackTabListsTheChatsAndOpensOne() {
        app.launchArguments = ["-PRHubPaired", "-PRHubFeedback"]
        app.launch()
        app.go(to: .feedback)
        let request = app.staticTexts["Open a PR's Linear ticket from its page"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10), "the feedback list")
        XCTAssertTrue(app.buttons["feedback-new"].firstMatch.exists, "New feedback")
        request.tap()
        XCTAssertTrue(text(containing: "Shipped in build 310").waitForExistence(timeout: 10), "the chat")
    }

    func testATappedFeedbackPushOpensItsChat() {
        app.launchArguments = ["-PRHubPaired", "-PRHubFeedback", "-PRHubFeedbackPush", "fb_sample_filter"]
        app.launch()
        XCTAssertTrue(
            text(containing: "Shipped in build 305").waitForExistence(timeout: 15),
            "Feedback shows on the chat the push named"
        )
        recordScreenshot("feedback-push-opened")
    }

    func testAWorkerWithNoFeedbackHasNoFeedbackTab() {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
        XCTAssertTrue(app.tab(.prs).waitForExistence(timeout: 15))
        XCTAssertFalse(app.tab(.feedback).exists)
    }
}
