import XCTest

@MainActor
final class PRHubOutboxCheckTests: PRHubUITestCase {
    func testEachJobWaitsInItsOwnWordsAndLands() throws {
        app.launchArguments = ["-PRHubOutboxCheck"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["prhub-ui-fixture-status"].firstMatch.waitForExistence(timeout: 10))
        app.go(to: .prs)
        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        checkout.tap()

        app.buttons["Comment"].tap()
        let field = app.descendants(matching: .any)["inline-composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Online comment")
        app.buttons["inline-composer-send"].tap()
        XCTAssertTrue(app.staticTexts["Online comment"].waitForExistence(timeout: 5), "the Worker saved the comment")
        let toast = app.descendants(matching: .any)["pr-review-toast-words"].firstMatch

        try setWorker("down")
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.buttons["inline-composer-send"].waitForExistence(timeout: 5))
        app.buttons["inline-composer-send"].tap()
        XCTAssertTrue(waitFor { toast.exists && toast.label == "Submitting review…" })
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))
        XCTAssertEqual(toast.label, "Submitting review…", "past the screen's wait it still says so, never red")

        app.buttons["pr-ask"].tap()
        let askField = app.descendants(matching: .any)["sessionReplyField"].firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 5))
        let readProblem = app.staticTexts["pr-ask-read-problem"]
        XCTAssertTrue(readProblem.waitForExistence(timeout: 10))
        XCTAssertEqual(readProblem.label, "Can't reach the Worker. The chat shows again when it's back.")
        askField.tap()
        askField.typeText("Is it tested?")
        app.buttons["sessionReplySend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pr-ask-sending"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-failed"].exists)

        try setWorker("up")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stand-in Worker'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-failed"].exists)
        app.buttons["Done"].tap()
        let approved = app.buttons["pr-review-approve"]
        XCTAssertTrue(waitFor { approved.isSelected }, "the queued review also landed")

        try setWorker("down")
        app.buttons["Comment"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Please refuse this")
        app.buttons["inline-composer-send"].tap()
        XCTAssertTrue(waitFor { toast.exists && toast.label == "Posting comment…" })
        RunLoop.current.run(until: Date.now.addingTimeInterval(2))
        app.back()
        try setWorker("up")
        XCTAssertTrue(waitFor(timeout: 20) { toast.exists && toast.label.hasPrefix("Comment not sent.") })
        XCTAssertTrue(app.buttons["pr-review-toast-retry"].exists)
    }

    private func setWorker(_ state: String) throws {
        try XCUIDevice.shared.system.open(XCTUnwrap(URL(string: "prhub-pr://ui-test-outbox?state=\(state)")))
        let status = app.descendants(matching: .any)["prhub-ui-fixture-status"].firstMatch
        XCTAssertTrue(waitFor { status.exists && status.label == state }, "the fixture acknowledged \(state)")
    }
}
