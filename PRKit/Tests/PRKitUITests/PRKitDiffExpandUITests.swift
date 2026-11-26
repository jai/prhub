import XCTest

/// The lines a diff leaves out, on `-PRHubHiddenLines`' PR: `src/checkout/charge.ts` has two hunks, with seven lines
/// left out over the first, eleven between them and eleven after; `src/billing/money.ts` is renamed with nothing
/// changed; `src/checkout/rates.json` can't be read with `-PRHubFileTooLarge`. A gap's row shows its lines and "Show
/// less" takes them back; a long press on a file's header has "Show whole file"; a read that failed says why. What the
/// rows are and what is read is `DiffGapTests`' and `PRHiddenLinesTests`'. One launch a test. Pictures stay in the
/// test's result bundle.
@MainActor
final class PRKitDiffExpandUITests: PRHubUITestCase {
    private static let title = "Charge a card once for each order"
    private static let whole = "Show whole file"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    /// A row for each run of lines the diff leaves out, each saying how many where the hunks say so.
    func testTheDiffOffersTheLinesItLeavesOut() {
        openDiff()
        let before = app.cells["diff-gap-0-0"]
        XCTAssertTrue(before.waitForExistence(timeout: 5), "over the first hunk")
        XCTAssertEqual(before.label, "Show 7 hidden lines")
        let between = app.cells["diff-gap-0-1"]
        XCTAssertTrue(between.exists, "between the two hunks")
        XCTAssertEqual(between.label, "Show 11 hidden lines")
        XCTAssertFalse(hiddenLine(5).exists, "nothing is shown until it is asked for")
        recordScreenshot("expand-before")
    }

    /// A tap shows the gap's lines, numbered as the file numbers them, and "Show less" under them takes them back.
    func testAGapsRowShowsItsLinesAndShowLessTakesThemBack() {
        openDiff()
        let gap = app.cells["diff-gap-0-0"]
        XCTAssertTrue(gap.waitForExistence(timeout: 5))
        gap.tap()
        XCTAssertTrue(hiddenLine(5).waitForExistence(timeout: 5), "the file's fifth line, which the diff left out")
        XCTAssertTrue(words("FIRST-LINE-OF-CHARGE").exists, "with its code")
        XCTAssertTrue(hiddenLine(1).exists && hiddenLine(7).exists, "all seven")
        XCTAssertFalse(hiddenLine(8).exists, "line 8 is the hunk's own")
        XCTAssertFalse(app.cells["diff-gap-0-0"].exists, "the row gave way to its lines")
        let less = app.cells["diff-gap-less-0-0"]
        XCTAssertTrue(less.exists, "Show less, under them")
        XCTAssertEqual(less.label, "Show less")
        recordScreenshot("expand-gap-open")

        less.tap()
        XCTAssertTrue(waitFor { !self.hiddenLine(5).exists }, "the lines go")
        XCTAssertTrue(app.cells["diff-gap-0-0"].waitForExistence(timeout: 5), "and their row is back")
        XCTAssertEqual(app.cells["diff-gap-0-0"].label, "Show 7 hidden lines", "reading as it did")
    }

    /// A long press on a file's header: "Show whole file" opens every gap of the file, and the same words turn it off.
    func testShowWholeFileShowsEveryLineOfTheFile() {
        openDiff()
        XCTAssertTrue(app.cells["diff-gap-0-0"].waitForExistence(timeout: 5))
        openHeaderMenu()
        app.buttons[Self.whole].firstMatch.tap()
        XCTAssertTrue(hiddenLine(1).waitForExistence(timeout: 5), "the file's first line")
        XCTAssertTrue(hiddenLine(7).exists, "down to the first hunk")
        XCTAssertFalse(app.cells["diff-gap-0-0"].exists, "no gap is left to open")
        XCTAssertFalse(app.cells["diff-gap-less-0-0"].exists, "the header's menu puts it back, not a row")
        recordScreenshot("expand-whole-file")

        openHeaderMenu()
        let item = app.buttons[Self.whole].firstMatch
        XCTAssertEqual(item.label, Self.whole, "the same words while it is on")
        recordScreenshot("expand-whole-file-menu")
        item.tap()
        XCTAssertTrue(waitFor { !self.hiddenLine(1).exists }, "the file goes back to its hunks")
        XCTAssertTrue(app.cells["diff-gap-0-0"].waitForExistence(timeout: 5))
    }

    /// A file too large to read: its gap's row says so, with Try again.
    func testAFileThatCantBeReadSaysWhy() {
        openDiff(["-PRHubFileTooLarge"])
        let gap = app.cells["diff-gap-2-0"]
        let table = diffTable
        let screen = app.windows.firstMatch.frame
        // Clear of the file's header above and of the review bar below, where a tap would land on them.
        let canTap = {
            gap.exists && gap.isHittable && gap.frame.midY > screen.minY + screen.height * 0.2
                && gap.frame.midY < screen.minY + screen.height * 0.8
        }
        // `while`, not `for … where`: it stops asking at the first yes.
        var swipes = 0
        while swipes < 8, !canTap() {
            table.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(canTap(), "rates.json's first gap")
        app.waitForStill(gap)
        XCTAssertEqual(gap.label, "Show 4 hidden lines")
        gap.tap()
        let reason = app.staticTexts["diff-gap-failure"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "why, on the gap's row")
        XCTAssertEqual(reason.label, "This file is too large to show.")
        let retry = app.buttons["diff-gap-retry-2-0"].firstMatch
        XCTAssertTrue(retry.exists, "Try again")
        XCTAssertEqual(retry.label, "Try again")
        recordScreenshot("expand-failed")
    }

    // MARK: - Steps

    private func openDiff(_ arguments: [String] = []) {
        app.launch(["-PRHubPaired", "-PRHubHiddenLines", "-prhubAlertsDeclined", "YES"] + arguments, appearance: .light)
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

    private var diffTable: XCUIElement {
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        return app.tables.containing(.cell, identifier: lines.firstMatch.identifier).firstMatch
    }

    /// A long press on the first file's header, until its menu is up.
    private func openHeaderMenu() {
        let header = app.buttons["file-header-0"]
        XCTAssertTrue(header.exists && header.isHittable, "the file's header")
        header.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons[Self.whole].firstMatch.waitForExistence(timeout: 5), "Show whole file, in its menu")
    }
}
