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

    /// The tab says how many chats have a question not answered yet, before Feedback is opened (Jai, 2026-11-24:
    /// "expose it as a badge on the tab bar"); with none, it says nothing.
    func testAnOpenQuestionBadgesTheFeedbackTab() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's bar draws its badge another way")
        app.launchArguments = ["-PRHubPaired", "-PRHubFeedback", "-PRHubFeedbackAsks"]
        app.launch()
        let tab = app.tab(.feedback)
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "the Feedback tab")
        // The tab says its badge in its value, "1 needs you": the app's words, as iOS 26 reads no badge out of a tab.
        let badged = NSPredicate { tab, _ in ((tab as? XCUIElement)?.value as? String ?? "").hasPrefix("1") }
        wait(for: [expectation(for: badged, evaluatedWith: tab)], timeout: 15)
        recordScreenshot("feedback-tab-badged")
    }

    func testWithNoOpenQuestionTheFeedbackTabHasNoBadge() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's bar draws its badge another way")
        app.launchArguments = ["-PRHubPaired", "-PRHubFeedback"]
        app.launch()
        app.go(to: .feedback)
        XCTAssertTrue(app.buttons["feedback-new"].firstMatch.waitForExistence(timeout: 10), "the list has been read")
        XCTAssertEqual(app.tab(.feedback).value as? String ?? "", "", "two chats, neither with a question")
    }

    func testAWorkerWithNoFeedbackHasNoFeedbackTab() {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
        XCTAssertTrue(app.tab(.prs).waitForExistence(timeout: 15))
        XCTAssertFalse(app.tab(.feedback).exists)
    }
}
