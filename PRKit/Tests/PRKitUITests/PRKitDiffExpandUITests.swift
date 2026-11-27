import XCTest

/// The lines a diff leaves out, on `-PRHubHiddenLines`' PR, the sample acme/web#431: `src/checkout/charge.ts` has two
/// hunks, with seven lines left out over the first, eleven between them and eleven after. One walk, one launch: a
/// gap's row shows its lines and "Show less" takes them back; a long press on the file's header has "Show whole file".
/// What the rows are and say is `DiffGapTests`' and `DiffGapRowTests`', what is read is `PRHiddenLinesTests`', and a
/// read that failed is drawn in `DiffGapFailureTests`.
@MainActor
final class PRKitDiffExpandUITests: PRHubUITestCase {
    private static let title = "Charge a card once for each order"
    private static let whole = "Show whole file"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    func testAGapsRowShowsItsLinesShowLessTakesThemBackAndShowWholeFileShowsEveryLine() {
        openDiff()
        let gap = app.cells["diff-gap-0-0"]
        XCTAssertTrue(gap.waitForExistence(timeout: 5), "over the first hunk")
        XCTAssertFalse(hiddenLine(5).exists, "nothing is shown until it is asked for")

        // A tap shows the gap's lines, numbered as the file numbers them, with "Show less" under them.
        gap.tap()
        XCTAssertTrue(hiddenLine(5).waitForExistence(timeout: 5), "the file's fifth line, which the diff left out")
        XCTAssertTrue(words("FIRST-LINE-OF-CHARGE").exists, "with its code")
        XCTAssertTrue(hiddenLine(1).exists && hiddenLine(7).exists, "all seven")
        XCTAssertFalse(hiddenLine(8).exists, "line 8 is the hunk's own")
        XCTAssertFalse(app.cells["diff-gap-0-0"].exists, "the row gave way to its lines")
        let less = app.cells["diff-gap-less-0-0"]
        XCTAssertTrue(less.exists, "Show less, under them")

        less.tap()
        XCTAssertTrue(waitFor { !self.hiddenLine(5).exists }, "the lines go")
        XCTAssertTrue(app.cells["diff-gap-0-0"].waitForExistence(timeout: 5), "and their row is back")
        XCTAssertEqual(app.cells["diff-gap-0-0"].label, "Show 7 hidden lines", "reading as it did")

        // A long press on the file's header: "Show whole file" opens every gap of the file.
        openHeaderMenu()
        app.buttons[Self.whole].firstMatch.tap()
        XCTAssertTrue(hiddenLine(1).waitForExistence(timeout: 5), "the file's first line")
        XCTAssertTrue(hiddenLine(7).exists, "down to the first hunk")
        XCTAssertFalse(app.cells["diff-gap-0-0"].exists, "no gap is left to open")
        XCTAssertFalse(app.cells["diff-gap-less-0-0"].exists, "the header's menu puts it back, not a row")

        // The same words turn it off.
        openHeaderMenu()
        let item = app.buttons[Self.whole].firstMatch
        XCTAssertEqual(item.label, Self.whole, "the same words while it is on")
        item.tap()
        XCTAssertTrue(waitFor { !self.hiddenLine(1).exists }, "the file goes back to its hunks")
        XCTAssertTrue(app.cells["diff-gap-0-0"].waitForExistence(timeout: 5))
    }

    // MARK: - Steps

    private func openDiff() {
        app.launch(["-PRHubPaired", "-PRHubHiddenLines", "-prhubAlertsDeclined", "YES"], appearance: .light)
        app.openPR(Self.title)
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(app.reveal(files), "Files changed, on the PR's page")
        files.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 10), "the diff")
    }

    /// Line `number` of `charge.ts`, shown from the file's text.
    private func hiddenLine(_ number: Int) -> XCUIElement {
        app.cells["diff-hidden-line-0-\(number)"]
    }

    private func words(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A long press on the first file's header, until its menu is up.
    private func openHeaderMenu() {
        let header = app.buttons["file-header-0"]
        XCTAssertTrue(header.exists && header.isHittable, "the file's header")
        header.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons[Self.whole].firstMatch.waitForExistence(timeout: 5), "Show whole file, in its menu")
    }
}
