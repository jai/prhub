import XCTest

/// A Settings change to the diff's font redraws a diff already open in the PRs tab. The faces and sizes themselves are
/// the rendering tests' (`DiffViewedMarkTests`, PRKit's `DiffFontTests`); their pictures are `PRHubDiffScreenshotTests`'.
@MainActor
final class PRHubDiffFontUITests: PRHubUITestCase {
    func testSettingsChangesAnOpenDiff() throws {
        // No font argument: it would override what Settings stores.
        openDiff()
        let line = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let before = line.frame.height

        app.go(to: .settings)
        let preview = app.descendants(matching: .any)["diff-font-preview"]
        XCTAssertTrue(app.scrollSettings(to: preview))
        try recordScreenshot("diff-font-settings-before")
        let bigger = app.descendants(matching: .any)["diff-font-size"].buttons["Bigger"]
        for _ in 0 ..< 4 {
            bigger.tap()
        }
        let face = app.buttons["diff-font-jetBrainsMono"]
        XCTAssertTrue(app.scrollSettings(to: face))
        face.tap()
        XCTAssertTrue(app.scrollSettings(to: preview, up: false))
        try recordScreenshot("diff-font-settings-after")

        app.go(to: .prs)
        XCTAssertTrue(waitFor { line.exists && line.frame.height > before }, "the open diff redrew at 16 pt")
        try recordScreenshot("diff-font-live-update")
    }

    private func openDiff() {
        app.launch(["-PRHubPaired"], appearance: .light)
        let row = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // Files changed: the diff with its panel waiting, the code all there is.
        let diff = app.buttons["pr-files-changed"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-viewed-0"].waitForExistence(timeout: 5))
    }
}
