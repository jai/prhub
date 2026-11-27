import XCTest

/// A tap on a PR's Linear ticket opens the ticket over PRHub, from its row in the list and from the PR's page (Jai's
/// feedback, 2026-11-24: "I can't tap on the Linear ticket on a PR view"). The Simulator has no Linear app, so iOS
/// refuses the universal link and the ticket opens in the browser sheet over PRHub: the app stays in front. That is
/// the system's answer and a sheet over the screen, which only the running app shows; one walk covers both places.
/// That each ticket is a finger high is `PRPageHeaderRenderingTests`' and `PRRowCardRenderingTests`'.
@MainActor
final class PRKitTicketLinkUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"

    func testATapOnATicketOpensItOverThePRAndOverTheList() {
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-PRHubPaired"]
        app.launch()

        // The PR's ticket, on its page.
        app.openPR(checkout)
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        let tickets = app.descendants(matching: .any)["pr-tickets"].firstMatch
        XCTAssertTrue(tickets.waitForExistence(timeout: 5), "the PR's page lists its tickets")
        let ticket = tickets.buttons.firstMatch
        XCTAssertTrue(ticket.exists, "the ticket is a button")
        XCTAssertTrue(ticket.label.contains("WEB-31"), ticket.label)
        XCTAssertTrue(app.isClearOfBars(ticket), "on the page's first screen")
        let pageTicket = ticket.frame
        ticket.tap()
        assertTheTicketIsOpenOverPRHub()
        closeTheBrowser()
        XCTAssertTrue(app.buttons["pr-review-changes"].exists, "the PR is still under the ticket")

        // The row's ticket, in the list: back to it on a phone; a wide screen has it beside the PR.
        if !app.isWide {
            app.back()
        }
        XCTAssertTrue(app.staticTexts[checkout].waitForExistence(timeout: 10))
        // Beside the PR, the row's ticket is the one in the list's column, before the page's.
        let named = app.buttons.matching(NSPredicate(format: "label CONTAINS 'WEB-31'"))
        let inList = app.isWide ? named.allElementsBoundByIndex.first { $0.frame.maxX <= pageTicket.minX } : nil
        let rowTicket = inList ?? named.firstMatch
        for _ in 0 ..< 10 where !app.isClearOfBars(rowTicket) {
            app.swipeUp(velocity: .slow)
        }
        app.waitForStill(rowTicket)
        XCTAssertTrue(app.isClearOfBars(rowTicket), "the row's ticket is a button on screen")
        let hadPR = app.buttons["pr-review-changes"].exists
        rowTicket.tap()
        assertTheTicketIsOpenOverPRHub()
        XCTAssertEqual(app.buttons["pr-review-changes"].exists, hadPR, "the ticket's tap is not the row's: no PR opened")
    }

    private var browser: XCUIElement {
        app.descendants(matching: .any)["pr-ticket-browser"].firstMatch
    }

    /// The browser sheet is up with the ticket, and PRHub is still the app in front.
    private func assertTheTicketIsOpenOverPRHub() {
        XCTAssertTrue(browser.waitForExistence(timeout: 10), "the ticket opens in a browser sheet")
        XCTAssertEqual(app.state, .runningForeground, "PRHub stays in front")
    }

    /// Closes the browser sheet by its own button, or else by pulling it down, and waits for it to go.
    private func closeTheBrowser() {
        let close = ["Done", "Close", "Cancel"].map { app.buttons[$0] }.first { $0.waitForExistence(timeout: 3) }
        if let close {
            close.tap()
        } else {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        XCTAssertTrue(waitFor(timeout: 10) { !browser.exists }, "the browser sheet has gone, and the list is back")
    }
}
