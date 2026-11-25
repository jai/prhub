import XCTest

/// A line too long for the screen is read to its last character without scrolling sideways: a dashboard saved as one
/// minified line, a README's paragraphs, a long comment, string and call, a tab-indented command and a minified script
/// (a teammate's feedback, 2026-11-25: each was cut at 160 columns with no way to the rest). On `-PRHubLongLines`' PR,
/// every line of which ends in a word of its own.
@MainActor
final class PRKitDiffLongLineUITests: PRHubUITestCase {
    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let title = "Move the checkout dashboard to the new panels"

    // One launch a file: a long walk is several tests, so a slow or failed file fails alone.

    func testAMinifiedDashboardsLastCharactersCanBeReached() throws {
        openDiff(bytes: 5000)
        show(file: "dashboards/checkout.json")
        recordScreenshot("long-lines-1-json-start")
        showFullLine()
        try reach("END-OF-JSON", in: nil, picture: "long-lines-1-json")
    }

    func testAReadmesParagraphsCanBeReadToTheirEnds() throws {
        openDiff(bytes: 5000)
        try reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md", picture: "long-lines-2-readme")
        try reach("END-OF-LONG-PARAGRAPH", in: nil, picture: "long-lines-3-readme-long")
    }

    func testALongCommentStringAndCallCanBeReadToTheirEnds() throws {
        openDiff(bytes: 5000)
        try reach("END-OF-COMMENT", in: "Sources/Checkout/RetryPolicy.swift", picture: "long-lines-4-code")
        try reach("END-OF-STRING", in: nil, picture: nil)
        try reach("END-OF-CALL", in: nil, picture: nil)
        try reach("END-OF-TABS", in: "Makefile", picture: "long-lines-5-tabs")
    }

    func testAMinifiedScriptsLastCharactersCanBeReached() throws {
        openDiff(bytes: 5000)
        show(file: "vendor/retry.min.js")
        showFullLine()
        try reach("END_OF_SCRIPT()", in: nil, picture: "long-lines-6-minified")
    }

    func testAParagraphsLastCharactersCanBeReachedInTheLargestText() throws {
        openDiff(bytes: 5000, textSize: Self.largest)
        try reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md", picture: "long-lines-largest-readme")
    }

    func testEveryLongLinesLastCharactersCanBeReachedInTheDark() throws {
        openDiff(bytes: 5000, appearance: .dark)
        try reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md", picture: "long-lines-dark-readme")
        try reach("END-OF-COMMENT", in: "Sources/Checkout/RetryPolicy.swift", picture: "long-lines-dark-code")
    }

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
        recordScreenshot("long-lines-7-json-54kb")
        old.tap()
        let next = app.cells["diff-line-4-piece-1"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the line goes on past where it was cut")
        XCTAssertFalse(old.exists)
        recordScreenshot("long-lines-8-full-line")
        let less = app.cells["diff-line-4-less"]
        let table = diffTable
        for _ in 0 ..< 60 where !(less.exists && less.isHittable) {
            table.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(less.exists && less.isHittable, "Show less, under the line's end")
        app.waitForStill(less)
        recordScreenshot("long-lines-9-show-less")
        less.tap()
        XCTAssertTrue(waitFor { !self.app.cells["diff-line-4-less"].exists }, "the line is cut again")
    }

    /// The panel's Wrap lines switch: off, a long line is one row again, cut with its mark; on, it is whole.
    func testWrapLinesCanBeTurnedOffAndOn() throws {
        openDiff(bytes: 5000)
        try reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md", picture: nil)
        setWrapLines("off")
        show(file: "dashboards/README.md")
        XCTAssertFalse(text(endingIn: "END-OF-SHORT-PARAGRAPH").exists, "one row a line: the paragraph is cut")
        XCTAssertTrue(text(endingIn: "⋯").firstMatch.waitForExistence(timeout: 5))
        recordScreenshot("long-lines-10-wrap-off")
        setWrapLines("on")
        try reach("END-OF-SHORT-PARAGRAPH", in: "dashboards/README.md", picture: nil)
    }

    /// The PR's own description, on its page: a long paragraph and a link with no break in it wrap in the page's width.
    /// A wide table and wide code scroll sideways there, in their own room (DESIGN.md, Markdown).
    func testALongDescriptionWrapsOnThePRsPage() {
        launch(bytes: 5000)
        app.openPR(Self.title)
        let screen = app.windows.firstMatch.frame
        for tail in ["END-OF-DESCRIPTION-PARAGRAPH", "END-OF-LINK"] {
            let words = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", tail)).firstMatch
            XCTAssertTrue(app.reveal(words), "\(tail), in the description")
            XCTAssertGreaterThanOrEqual(words.frame.minX, screen.minX, "\(tail): nothing is off the left side")
            XCTAssertLessThanOrEqual(words.frame.maxX, screen.maxX, "\(tail): nothing is off the right side")
            recordScreenshot("long-description-\(tail)")
        }
    }

    // MARK: - Steps

    private func launch(bytes: Int, textSize: String? = nil, appearance: XCUIDevice.Appearance = .light) {
        app.launch(
            ["-PRHubPaired", "-PRHubLongLines", "-PRHubLongLineBytes", "\(bytes)", "-prhubAlertsDeclined", "YES"]
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: appearance
        )
    }

    private func openDiff(bytes: Int, textSize: String? = nil, appearance: XCUIDevice.Appearance = .light) {
        launch(bytes: bytes, textSize: textSize, appearance: appearance)
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

    /// Taps the first "Show full line" down from where the diff is.
    private func showFullLine() {
        let rests = app.cells.matching(NSPredicate(format: "identifier ENDSWITH '-rest'"))
        let table = diffTable
        var rest = rests.allElementsBoundByIndex.first(where: \.isHittable)
        for _ in 0 ..< 10 where rest == nil {
            table.swipeUp(velocity: .slow)
            rest = rests.allElementsBoundByIndex.first(where: \.isHittable)
        }
        recordScreenshot("long-lines-show-full-line")
        XCTAssertNotNil(rest, "Show full line, under the line's start")
        rest?.tap()
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

    /// Reads down from `path`'s first line (or from where the diff is) until the line that ends in `tail` has its end
    /// on screen: its last row above the screen's foot, and all of it between the screen's sides.
    private func reach(_ tail: String, in path: String?, picture: String?) throws {
        if let path {
            show(file: path)
            if let picture {
                recordScreenshot("\(picture)-start")
            }
        }
        let line = text(endingIn: tail)
        let table = diffTable
        let screen = app.windows.firstMatch.frame
        // Its last row above the foot of the screen, by a row's height at least: the diff's last line stops over the
        // floating controls.
        let isRead = { line.exists && line.frame.maxY > screen.minY + 60 && line.frame.maxY < screen.maxY - 20 }
        for _ in 0 ..< 60 where !isRead() {
            table.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(isRead(), "the end of the line, \(tail), is on screen")
        app.waitForStill(line)
        XCTAssertGreaterThanOrEqual(line.frame.minX, screen.minX, "\(tail): nothing is off the left side")
        XCTAssertLessThanOrEqual(line.frame.maxX, screen.maxX, "\(tail): nothing is off the right side")
        if let picture {
            recordScreenshot("\(picture)-end")
        }
    }
}
