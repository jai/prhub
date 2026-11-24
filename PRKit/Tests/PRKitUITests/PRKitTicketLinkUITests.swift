import XCTest

/// A PR's Linear ticket is a button that opens the ticket, on the PR's page and on its row in the list (Jai's feedback,
/// 2026-11-24: on the page the line was 16 pt tall and read as text). The Simulator has no Linear app, so the ticket
/// opens in the browser sheet over PRHub: the app stays in front.
@MainActor
final class PRKitTicketLinkUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"
    /// The least a finger needs (`PRStyle.rowHeight`), less the half point a frame loses to a screen's pixels: a row
    /// came back as 43.99999999999997.
    private let rowHeight: CGFloat = 43.5

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
    }

    func testATapOnAPRsTicketOpensItOverThePR() {
        app.openPR(checkout)
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        let tickets = app.descendants(matching: .any)["pr-tickets"].firstMatch
        XCTAssertTrue(tickets.waitForExistence(timeout: 5), "the PR's page lists its tickets")
        let ticket = tickets.buttons.firstMatch
        XCTAssertTrue(ticket.exists, "the ticket is a button")
        XCTAssertTrue(ticket.label.contains("WEB-31"), ticket.label)
        XCTAssertGreaterThanOrEqual(ticket.frame.height, rowHeight, "a finger's height at least")
        XCTAssertTrue(app.isClearOfBars(ticket), "on the page's first screen")
        recordScreenshot("pr-page-ticket")

        ticket.tap()
        assertTheTicketIsOpenOverPRHub()
        recordScreenshot("pr-page-ticket-open")
    }

    func testATapOnARowsTicketOpensItOverTheList() {
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let ticket = app.buttons.matching(NSPredicate(format: "label CONTAINS 'WEB-31'")).firstMatch
        for _ in 0 ..< 10 where !app.isClearOfBars(ticket) {
            app.swipeUp(velocity: .slow)
        }
        app.waitForStill(ticket)
        XCTAssertTrue(app.isClearOfBars(ticket), "the row's ticket is a button on screen")
        XCTAssertGreaterThanOrEqual(ticket.frame.height, rowHeight, "a finger's height at least")

        // A wide screen may already have a PR beside the list.
        let hadPR = app.buttons["pr-review-changes"].exists
        ticket.tap()
        assertTheTicketIsOpenOverPRHub()
        XCTAssertEqual(app.buttons["pr-review-changes"].exists, hadPR, "the ticket's tap is not the row's: no PR opened")
        recordScreenshot("pr-row-ticket-open")
    }

    /// The browser sheet is up with the ticket, and PRHub is still the app in front.
    private func assertTheTicketIsOpenOverPRHub() {
        let browser = app.descendants(matching: .any)["pr-ticket-browser"].firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 10), "the ticket opens in a browser sheet")
        XCTAssertEqual(app.state, .runningForeground, "PRHub stays in front")
    }
}
