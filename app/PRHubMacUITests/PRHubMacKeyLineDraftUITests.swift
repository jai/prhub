import XCTest

/// A key line's words into the review, on the Mac, over the sample PR acme/web#412: its note under the line has Copy
/// and Add to review, the press opens the line's box with the key line's words in it, and the box's Add to review
/// keeps them as a pending comment and ticks the note's control. Pictures stay in the test's result bundle.
@MainActor
final class PRHubMacKeyLineDraftUITests: XCTestCase {
    private let app = XCUIApplication()
    private let line = "src/checkout/CheckoutError.tsx:RIGHT:9"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The app's window alone, never the whole screen.
    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Not `async`: with `continueAfterFailure` off, a failed assertion in an async test never returned.
    func testAKeyLinesWordsAreAddedToTheReviewFromItsNote() {
        // No windows of an earlier run. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Show a retry button when checkout fails"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the sample PR's card")
        app.activate()
        card.click()

        let review = app.buttons["pr-review-changes"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15), "the PR's page")
        review.click()
        let row = element("key-line-\(line)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the panel open on Key lines")
        XCTAssertTrue(element("key-line-copy-\(line)").exists, "Copy, on the key line's row")
        XCTAssertTrue(element("key-line-add-\(line)").exists, "Add to review, on the key line's row")
        row.click()

        let add = element("key-line-note-add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add to review, on the note under the line")
        XCTAssertTrue(element("key-line-note-copy").exists, "Copy, on the note")
        picture("mac-key-line-note")

        add.click()
        let send = element("inline-composer-send")
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the line's box, with the key line's words in it")
        send.click()

        // The tick is read from the review's pending comments: it says the comment is kept.
        for _ in 0 ..< 50 where add.value as? String != "added" {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        XCTAssertEqual(add.value as? String, "added", "kept, and the note's control is ticked")
        picture("mac-key-line-added")
    }
}
