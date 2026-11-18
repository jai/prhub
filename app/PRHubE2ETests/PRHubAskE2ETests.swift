import XCTest

/// A new question through the dedicated deployed Worker. Pairing is verified before any question is sent.
@MainActor
final class PRHubAskE2ETests: E2ETestCase {
    func testAFreshQuestionReceivesItsCorrelatedAnswer() async throws {
        let target = try E2ETarget.load()
        launch()
        try verifyPairing(target)
        try await openPR(target)
        let ask = app.buttons["pr-ask"]
        try require(ask.waitForExistence(timeout: 30), "Ask must be enabled for the dedicated test PR.")
        ask.tap()
        let field = app.descendants(matching: .any)["sessionReplyField"].firstMatch
        try require(field.waitForExistence(timeout: 10), "Ask's input field must appear.")
        let messages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat-message-agent-"
        ))
        let earlier = Set(messages.allElementsBoundByIndex.map(\.identifier))
        let nonce = UUID().uuidString
        let expected = "PRHUB-\(nonce)-FIVE"
        field.tap()
        if let draft = field.value as? String, !draft.isEmpty {
            // An old draft is not this run's question. A dedicated test account may safely replace it.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count))
        }
        field.typeText("What is two plus three? Reply with exactly \(expected) and nothing else.")
        app.buttons["sessionReplySend"].tap()

        let failed = app.descendants(matching: .any)["pr-ask-failed"]
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'back online'")).firstMatch
        let deadline = ContinuousClock.now + .seconds(180)
        var seen: Set<String> = []
        var answered = false
        while !answered {
            try require(!failed.exists, "The new question failed to send.")
            try require(!saved.exists, "The new question remained queued for network delivery.")
            for state in ["sending", "working"] where app.descendants(matching: .any)["pr-ask-\(state)"].exists {
                seen.insert(state)
            }
            answered = messages.allElementsBoundByIndex.contains { message in
                !earlier.contains(message.identifier)
                    && message.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch.exists
            }
            if !answered {
                try require(ContinuousClock.now < deadline, "No new assistant message answered this run's unique question.")
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        print("PRHUB-E2E-ASK run=\(nonce) pr=\(target.reference) observed=\(seen.sorted().joined(separator: ",")) answered=true")
        // Fast answers may legitimately bypass a sampled transient state; controlled UI tests cover those states.
        XCTAssertFalse(failed.exists)
    }
}
