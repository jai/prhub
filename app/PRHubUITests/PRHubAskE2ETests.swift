import XCTest

/// Ask against a real Worker, on an app paired with it (`PRHubPushOpenE2ETests.testPairing`): open the PR whose row
/// shows `TEST_RUNNER_PRHUB_E2E_ASK_ROW`, ask a question, and watch the sheet go Sending… → Thinking → the answer with
/// nothing red on the way. CI runs none of it.
@MainActor
final class PRHubAskE2ETests: XCTestCase {
    private let app = XCUIApplication()

    func testAskGoesSendingThinkingAnsweredWithNoError() throws {
        let row = ProcessInfo.processInfo.environment["PRHUB_E2E_ASK_ROW"]
        try XCTSkipUnless(row != nil, "an end-to-end run only")
        app.launchArguments = ["-PRHubSelfHosted", "YES"]
        app.launch()
        app.go(to: .prs)
        let pullRequest = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", row ?? "")).firstMatch
        XCTAssertTrue(pullRequest.waitForExistence(timeout: 60), "the PR's row")
        pullRequest.tap()
        let ask = app.buttons["pr-ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 30), "Ask on the PR")
        ask.tap()
        let field = app.textViews["sessionReplyField"].exists ? app.textViews["sessionReplyField"]
            : app.textFields["sessionReplyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ask's field")
        field.tap()
        field.typeText("What is two plus three? Answer with the number as one word in capitals, nothing else.")
        app.buttons["sessionReplySend"].tap()

        let sending = app.descendants(matching: .any)["pr-ask-sending"]
        let thinking = app.descendants(matching: .any)["pr-ask-working"]
        let failed = app.descendants(matching: .any)["pr-ask-failed"]
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'back online'")).firstMatch
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'FIVE'")).firstMatch
        var seen: [String] = []
        let started = Date.now
        while Date.now.timeIntervalSince(started) < 180, !answer.exists {
            XCTAssertFalse(failed.exists, "a failed send")
            XCTAssertFalse(saved.exists, "the outbox's Saved words")
            for (name, mark) in [("sending", sending), ("thinking", thinking)] where mark.exists && seen.last != name {
                seen.append(name)
            }
        }
        print("PRHUB-E2E-ASK-STATES=\(seen.joined(separator: ",")) answered=\(answer.exists)")
        XCTAssertTrue(answer.exists, "the agent's answer")
        XCTAssertTrue(seen.contains("thinking"), "Thinking while the agent works")
        XCTAssertFalse(failed.exists)
    }
}
