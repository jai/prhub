import XCTest

/// The outbox's states on a Simulator, against a stand-in Worker that a control port takes up and down
/// (`-PRHubOutboxCheck`, PRHubOutboxCheck.swift). `PRHUB_OUTBOX_CHECK` is the stand-in's URL; its control port is the
/// next one. A comment posts at once; a review sent while the Worker is down waits in the waiting tone, never red, and
/// lands when it is back; a question waits quietly; a write refused after its screen has gone says so on the list.
/// CI runs none of it.
@MainActor
final class PRHubOutboxCheckTests: XCTestCase {
    private let app = XCUIApplication()

    func testEachJobWaitsInItsOwnWordsAndLands() throws {
        let worker = ProcessInfo.processInfo.environment["PRHUB_OUTBOX_CHECK"]
        try XCTSkipUnless(worker != nil, "an outbox check only")
        let port = try XCTUnwrap(worker.flatMap(URL.init(string:))?.port)
        let control = "http://127.0.0.1:\(port + 1)"
        let setWorker: @Sendable (String) async throws -> Void = { state in
            _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "\(control)/\(state)")))
        }
        app.launchArguments = ["-PRHubOutboxCheck", worker ?? ""]
        app.launch()
        app.go(to: .prs)
        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 15))
        checkout.tap()

        // Online: a comment posts and says nothing.
        app.buttons["Comment"].tap()
        let field = app.descendants(matching: .any)["inline-composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Online comment")
        app.buttons["inline-composer-send"].tap()
        let notice = app.staticTexts["pr-notice"]
        XCTAssertFalse(notice.waitForExistence(timeout: 3), "a posted comment says nothing")

        // Worker down: a review waits, saved, in the waiting tone.
        try awaitTask { try await setWorker("down") }
        app.buttons["Approve"].tap()
        XCTAssertTrue(app.buttons["inline-composer-send"].waitForExistence(timeout: 5))
        app.buttons["inline-composer-send"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 25))
        XCTAssertEqual(notice.label, "Your review is saved on this phone and on its way to GitHub.")

        // A question while the Worker is down: Sending…, nothing red.
        app.buttons["pr-ask"].tap()
        let askField = app.textViews["sessionReplyField"].exists ? app.textViews["sessionReplyField"]
            : app.textFields["sessionReplyField"]
        XCTAssertTrue(askField.waitForExistence(timeout: 5))
        let readProblem = app.staticTexts["pr-ask-read-problem"]
        if readProblem.waitForExistence(timeout: 5) {
            XCTAssertEqual(readProblem.label, "Can't reach the Worker. The chat shows again when it's back.")
        }
        askField.tap()
        askField.typeText("Is it tested?")
        app.buttons["sessionReplySend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pr-ask-sending"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-failed"].exists)

        // Back up: the question and the review land.
        try awaitTask { try await setWorker("up") }
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stand-in Worker'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-failed"].exists)
        app.buttons["Done"].tap()

        // Down again: a comment the Worker will refuse, and Jai leaves before it does.
        try awaitTask { try await setWorker("down") }
        app.buttons["Comment"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Please refuse this")
        app.buttons["inline-composer-send"].tap()
        let saved = app.staticTexts.matching(
            NSPredicate(format: "label == 'Your comment is saved on this phone and on its way to GitHub.'")
        ).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 25))
        app.back()
        try awaitTask { try await setWorker("up") }
        let refusal = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'GitHub refused your comment “Please refuse this”'")
        ).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 20))
        sleep(3)
    }

    private func awaitTask(_ body: @escaping @Sendable () async throws -> Void) throws {
        let done = expectation(description: "control")
        Task {
            try? await body()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
