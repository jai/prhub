import XCTest

/// The lines a diff leaves out, on the Mac, over `-PRHubHiddenLines`' PR (`src/checkout/charge.ts`, two hunks): its
/// diff, an AppKit table no Simulator shows, has a row for each gap, and a right click on the file's header has "Show
/// whole file". Pictures stay in the test's result bundle.
@MainActor
final class PRHubMacExpandUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
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
    func testTheDiffOffersItsHiddenLinesAndShowsAWholeFile() {
        // No windows of an earlier run. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired", "-PRHubHiddenLines"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Charge a card once for each order"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the sample PR's card")
        app.activate()
        card.click()

        XCTAssertTrue(app.buttons["pr-review-changes"].firstMatch.waitForExistence(timeout: 15), "the PR's page")
        app.buttons["pr-files-changed"].firstMatch.click()
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "the diff")
        // A gap's row is a button with its own identifier. If the table gives a test no row to find, as it gives
        // none for its lines of code, the pictures are the check and the clicks go by place.
        let gap = app.buttons["diff-gap-0-0"].firstMatch
        let findsRows = gap.waitForExistence(timeout: 5)
        if findsRows {
            XCTAssertTrue([gap.label, gap.title].contains("Show 7 hidden lines"), "label \(gap.label), title \(gap.title)")
        }
        picture("mac-expand-before")

        // A right click on the file's header, the list's first row: by place, a few points under the table's top.
        table.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: table.frame.width / 2, dy: 14)).rightClick()
        let whole = app.menuItems["Show whole file"].firstMatch
        XCTAssertTrue(whole.waitForExistence(timeout: 5), "Show whole file, in the header's menu")
        whole.click()
        if findsRows {
            XCTAssertTrue(words("FIRST-LINE-OF-CHARGE").waitForExistence(timeout: 10), "a line the diff left out")
            XCTAssertFalse(app.buttons["diff-gap-0-0"].exists, "no gap is left to open")
        } else {
            // Long enough for the rows to land: there is nothing of the table's to wait on.
            _ = words("FIRST-LINE-OF-CHARGE").waitForExistence(timeout: 3)
        }
        picture("mac-expand-whole-file")
    }
}
