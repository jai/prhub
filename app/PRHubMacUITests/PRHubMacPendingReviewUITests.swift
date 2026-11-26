import XCTest

/// The review not submitted yet, on the Mac, over the sample PR that comes with one begun on github.com (acme/web#412):
/// its page lists the comment with no line in the diff, and its diff, an AppKit table no Simulator shows, has the
/// comment on a line under that line, with Edit and Delete. A line's box adds to that one review. Pictures stay in the
/// test's result bundle.
@MainActor
final class PRHubMacPendingReviewUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func words(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// The app's window alone, never the whole screen.
    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Not `async`: with `continueAfterFailure` off, a failed assertion in an async test never returned.
    func testThePendingReviewShowsOnThePRsPageAndUnderItsLineInTheDiff() {
        // No windows of an earlier run. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Show a retry button when checkout fails"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the sample PR's card")
        app.activate()
        card.click()

        XCTAssertTrue(app.buttons["pr-review-changes"].firstMatch.waitForExistence(timeout: 15), "the PR's page")
        XCTAssertTrue(element("pr-pending-list").waitForExistence(timeout: 5), "the page's list of pending comments")
        XCTAssertTrue(words("This file could use a test for the retry.").exists, "the comment on a whole file")
        XCTAssertTrue(words("src/checkout/CheckoutError.tsx").exists, "with its file's path")
        XCTAssertTrue(words("2 pending comments will go with your review").exists, "GitHub's count")
        picture("mac-pending-page")

        app.buttons["pr-files-changed"].firstMatch.click()
        XCTAssertTrue(words("Should a retry stop after a few tries?").waitForExistence(timeout: 15), "the comment on a line")
        XCTAssertTrue(app.buttons["pending-edit"].firstMatch.exists, "Edit")
        XCTAssertTrue(app.buttons["pending-delete"].firstMatch.exists, "Delete")
        picture("mac-pending-diff")

        // A click on a line of code opens its box, in the table. The Mac's table draws its code itself and gives a
        // test no row to find, so the click goes by place: the line the pending comment sits under, just over its card.
        let table = app.tables.firstMatch
        let edit = app.buttons["pending-edit"].firstMatch
        table.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: table.frame.width / 2, dy: edit.frame.minY - table.frame.minY - 30))
            .click()
        let send = app.buttons["inline-composer-send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the line's box")
        XCTAssertTrue([send.label, send.title].contains("Add to review"), "label \(send.label), title \(send.title)")
        XCTAssertFalse(app.buttons["Start review"].exists, "there is always one review to add to")
        picture("mac-pending-add-box")
    }
}
