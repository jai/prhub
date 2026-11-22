import XCTest

/// A PR's Ask AI chat after its sheet closed (Jai's feedback, fb_7cdbe8f2): a line on its row in the list, and on the PR's
/// page the toolbar's Ask AI tinted and a bar above the tabs; the bar is the PR's alone.
@MainActor
final class PRHubAskStatusUITests: PRHubUITestCase {
    private let line = "pr-row-ask-acme/web#412"

    func testAWorkingChatShowsOnItsRowAndOnItsPRsPage() throws {
        app.launchArguments = ["-PRHubPaired", "-PRHubAskState", "working"]
        app.launch()
        let row = app.buttons[line]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the chat's line on its PR's row")
        XCTAssertFalse(app.buttons["pr-ask-status-bar"].exists, "no bar on the list")
        recordScreenshot("ask-status-list-working")

        try XCUIDevice.shared.system.open(handoff("https://github.com/acme/web/pull/412"))
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pr-ask-status-bar"].waitForExistence(timeout: 5), "the bar on the PR's page")
        recordScreenshot("ask-status-pr-working")

        app.buttons["pr-ask-status-bar"].tap()
        XCTAssertTrue(app.navigationBars["web#412"].waitForExistence(timeout: 5), "the bar opens the chat")
    }

    func testAnAnswerWaitingOpensFromItsRow() {
        app.launchArguments = ["-PRHubPaired", "-PRHubAskState", "answered"]
        app.launch()
        let row = app.buttons[line]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains("Answer ready"))
        recordScreenshot("ask-status-list-answered")

        row.tap()
        XCTAssertTrue(app.navigationBars["web#412"].waitForExistence(timeout: 10), "the row's line opens the chat")
        recordScreenshot("ask-status-chat-opened")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pr-ask-status-bar"].exists, "read once opened")
        recordScreenshot("ask-status-pr-read")
    }

    private func handoff(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try XCTUnwrap(parts.url)
    }
}
