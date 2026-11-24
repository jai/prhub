import XCTest

/// Feedback on the Mac, which no Simulator shows. The phone has a Feedback tab; the Mac had only Window → Feedback
/// (⇧⌘F), which Jai did not find (2026-11-24: "Mac version doesn't have a feedback tab?"). Where the Worker serves
/// Feedback, the PRs window's toolbar has a Feedback button, which opens the Feedback window: the list, a chat beside
/// it, and New feedback with its composer and screenshots.
@MainActor
final class PRHubMacFeedbackUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func launch(_ arguments: [String]) {
        // No windows of an earlier run: each launch opens the PRs window alone. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        XCTAssertTrue(element("pr-list-page").waitForExistence(timeout: 30), "the PRs window")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// A row of the list, by its title: on the Mac a row is one button, labelled with its title and its age.
    private func row(_ title: String, in window: XCUIElement) -> XCUIElement {
        window.buttons.matching(identifier: "feedback-thread")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// A chat's words: on the Mac a text holds them as its value.
    private func words(_ words: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", words, words))
            .firstMatch
    }

    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testThePRsWindowOpensFeedbackFromItsToolbar() {
        launch(["-PRHubPaired", "-PRHubFeedback"])
        picture("prs-window")
        let feedback = element("prhub-mac-feedback")
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Feedback is in the PRs window's toolbar")

        // The Feedback window, by its identifier: its title becomes the open chat's. A click that only brought PRHub
        // back to the front, from under another app, is made again.
        let window = app.windows["prhub-feedback"]
        for _ in 0 ..< 3 where !window.exists {
            app.activate()
            feedback.click()
            _ = window.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(window.exists, "the Feedback window")

        // The list, as on the phone.
        let request = row("Open a PR's Linear ticket from its page", in: window)
        XCTAssertTrue(request.waitForExistence(timeout: 5), "the feedback list")
        XCTAssertTrue(row("Remember the org filter between launches", in: window).exists)

        // A chat, beside the list.
        request.click()
        XCTAssertTrue(
            words("Shipped in build 310", in: window).waitForExistence(timeout: 5),
            "the picked chat shows beside the list"
        )
        picture("feedback-chat")

        // New feedback: the composer, with a way to add a screenshot, and the agent's answer to what is sent.
        element("feedback-new").click()
        let field = element("sessionReplyField")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "New feedback opens a composer")
        XCTAssertTrue(element("composerAttach").exists, "the composer takes screenshots")
        field.click()
        // Few keys, and nothing below reads them back: on a Mac that runs other apps' UI tests too, another app can
        // come to the front mid-word and take the rest.
        field.typeText("Mac")
        app.buttons["sessionReplySend"].firstMatch.click()
        XCTAssertTrue(
            words("reply here with the build", in: window).waitForExistence(timeout: 20),
            "what was sent became a chat, and the agent's answer arrives in it"
        )
        XCTAssertEqual(window.buttons.matching(identifier: "feedback-thread").count, 3, "the new chat is in the list")
        picture("feedback-sent")
    }

    /// The toolbar's Feedback button says how many chats have a question not answered yet, as the phone's tab does.
    func testAnOpenQuestionIsCountedOnTheToolbarsFeedbackButton() {
        launch(["-PRHubPaired", "-PRHubFeedback", "-PRHubFeedbackAsks"])
        let feedback = element("prhub-mac-feedback")
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Feedback is in the PRs window's toolbar")
        let counted = NSPredicate { button, _ in ((button as? XCUIElement)?.value as? String ?? "").hasPrefix("1 ") }
        wait(for: [expectation(for: counted, evaluatedWith: feedback)], timeout: 15)
        picture("feedback-button-badged")
    }

    func testAWorkerWithNoFeedbackHasNoFeedbackButton() {
        launch(["-PRHubPaired"])
        XCTAssertFalse(element("prhub-mac-feedback").exists, "no Feedback button where the Worker serves none")
    }
}
