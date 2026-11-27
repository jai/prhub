import XCTest

/// What a long line asks of the running app: a tap on "Show full line" brings the rest of a very long line and
/// "Show less" takes it back, and the panel's Wrap lines switch turns wrapping off and on. On `-PRHubLongLines`' PR.
/// That every kind of long line is drawn to its last characters, in the light, the dark and the largest text, is the
/// rendering tests' (`DiffLongLineTests`, `DiffLongLineSampleTests`, `DiffLongLinePictureTests`), and the
/// description's wrapping is `PRLongDescriptionTests`'.
@MainActor
final class PRKitDiffLongLineUITests: PRHubUITestCase {
    private static let title = "Move the checkout dashboard to the new panels"

    /// 54 KB on one line, changed: the old line's start and the new one's, each over "Show full line", are one
    /// screen. A tap brings the rest; "Show less", under its end, takes it back.
    func testAVeryLongLineShowsItsStartThenTheRestWhenAsked() {
        openDiff(bytes: 54000)
        show(file: "dashboards/checkout.json")
        let screen = app.windows.firstMatch.frame
        let old = app.cells["diff-line-4-rest"]
        let new = app.cells["diff-line-5-rest"]
        XCTAssertTrue(old.waitForExistence(timeout: 5), "Show full line, under the old line's start")
        XCTAssertTrue(new.exists, "the new line's button is in the same screenful")
        XCTAssertLessThan(new.frame.minY - app.cells["diff-line-4"].frame.minY, screen.height, "both in a screen")
        XCTAssertFalse(app.cells["diff-line-4-piece-1"].exists)
        old.tap()
        let next = app.cells["diff-line-4-piece-1"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the line goes on past where it was cut")
        XCTAssertFalse(old.exists)
        let less = app.cells["diff-line-4-less"]
        let table = diffTable
        // `while`, not `for … where`: that asked the question sixty times over once the answer was yes.
        var swipes = 0
        while swipes < 60, !(less.exists && less.isHittable) {
            table.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(less.exists && less.isHittable, "Show less, under the line's end")
        app.waitForStill(less)
        less.tap()
        XCTAssertTrue(waitFor { !self.app.cells["diff-line-4-less"].exists }, "the line is cut again")
    }

    /// The panel's Wrap lines switch: off, a long line is one row, cut with its mark; on, it is whole again and read
    /// to its end. The diff opens wrapped, which `DiffLongLineTests` checks.
    func testWrapLinesCanBeTurnedOffAndOn() {
        openDiff(bytes: 5000)
        setWrapLines("off")
        show(file: "dashboards/README.md")
        XCTAssertFalse(text(endingIn: "END-OF-SHORT-PARAGRAPH").exists, "one row a line: the paragraph is cut")
        XCTAssertTrue(text(endingIn: "⋯").firstMatch.waitForExistence(timeout: 5))
        setWrapLines("on")
        reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md")
    }

    // MARK: - Steps

    private func openDiff(bytes: Int) {
        app.launch(
            ["-PRHubPaired", "-PRHubLongLines", "-PRHubLongLineBytes", "\(bytes)", "-prhubAlertsDeclined", "YES"],
            appearance: .light
        )
        app.openPR(Self.title)
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(app.reveal(files), "Files changed, on the PR's page")
        files.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 10))
    }

    private var diffTable: XCUIElement {
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        return app.tables.containing(.cell, identifier: lines.firstMatch.identifier).firstMatch
    }

    /// The row of code whose last characters are `tail`: at its end but for a quote or a bracket closing after it.
    private func text(endingIn tail: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*\\Q\(tail)\\E.{0,2}")).firstMatch
    }

    /// The panel's Files page, opened by its button where it is not already beside the code.
    private func openFiles() {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'file-row-'")).firstMatch
        // On a wide screen the panel is beside the code already, on whichever page it was left.
        if !row.exists, !app.segmentedControls.buttons["Files"].exists {
            let panel = app.buttons["diff-files"]
            if !panel.isHittable {
                // The bars and the panel's button leave as the code is read; a small scroll back brings them.
                diffTable.swipeDown(velocity: .slow)
            }
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.tap()
        }
        let files = app.segmentedControls.buttons["Files"]
        if files.waitForExistence(timeout: 3), !files.isSelected {
            files.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the panel's list of files")
    }

    /// The diff at `path`'s first line, by the panel's list of files.
    private func show(file path: String) {
        openFiles()
        let row = app.buttons["file-row-\(path)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), path)
        row.tap()
        app.closePanelOverDiff()
        app.waitForStill(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'")).firstMatch)
    }

    private func setWrapLines(_ value: String) {
        openFiles()
        let wrap = app.buttons["diff-wrap-lines"]
        XCTAssertTrue(wrap.waitForExistence(timeout: 5), "Wrap lines, under the list of files")
        if wrap.value as? String != value {
            wrap.tap()
        }
        XCTAssertTrue(waitFor { wrap.value as? String == value })
    }

    /// Reads down from `path`'s first line until the line that ends in `tail` has its end on screen: its last row above
    /// the screen's foot, and all of it between the screen's sides.
    private func reach(_ tail: String, in path: String) {
        show(file: path)
        let line = text(endingIn: tail)
        let table = diffTable
        let screen = app.windows.firstMatch.frame
        // Its last row above the foot of the screen, by a row's height at least: the diff's last line stops over the
        // floating controls.
        let isRead = { line.exists && line.frame.maxY > screen.minY + 60 && line.frame.maxY < screen.maxY - 20 }
        // `while`, not `for … where`: with the line in view that asked sixty times more, a minute and more on a slow
        // host, and one of those snapshots timed out (the iPad's job, 2026-11-25).
        var swipes = 0
        while swipes < 60, !isRead() {
            table.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(isRead(), "the end of the line, \(tail), is on screen")
        app.waitForStill(line)
        XCTAssertGreaterThanOrEqual(line.frame.minX, screen.minX, "\(tail): nothing is off the left side")
        XCTAssertLessThanOrEqual(line.frame.maxX, screen.maxX, "\(tail): nothing is off the right side")
    }
}
