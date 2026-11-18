import XCTest

/// The diff's controls across font settings: screenshots at small, default and large sizes in several faces, light
/// and dark; a 44 pt viewed target; and a Settings change that resizes an open diff. These checks do not compare
/// glyph rendering; the rendering target verifies font resolution. Over the
/// sample PRs, with the font set the way Settings stores it (`-prkit.diffFont face:size`). Pictures go to
/// `SCREENSHOTS_DIR` when set.
@MainActor
final class PRHubDiffFontUITests: PRHubUITestCase {
    // One launch a test: each font in each appearance is its own test. Two tests of nine launches each took up to
    // 8 minutes, and a slow CI Mac killed one (issue #56).

    func testTheDiffInSystem9Light() throws {
        try diff(in: "system:9", .light)
    }

    func testTheDiffInSystem12Light() throws {
        try diff(in: "system:12", .light)
    }

    func testTheDiffInSystem20Light() throws {
        try diff(in: "system:20", .light)
    }

    func testTheDiffInSourceCodePro12Light() throws {
        try diff(in: "sourceCodePro:12", .light)
    }

    func testTheDiffInJetBrainsMono16Light() throws {
        try diff(in: "jetBrainsMono:16", .light)
    }

    func testTheDiffInFiraCode9Light() throws {
        try diff(in: "firaCode:9", .light)
    }

    func testTheDiffInIbmPlexMono20Light() throws {
        try diff(in: "ibmPlexMono:20", .light)
    }

    func testTheDiffInMenlo12Light() throws {
        try diff(in: "menlo:12", .light)
    }

    func testTheDiffInCourierNew14Light() throws {
        try diff(in: "courierNew:14", .light)
    }

    func testTheDiffInSystem9Dark() throws {
        try diff(in: "system:9", .dark)
    }

    func testTheDiffInSystem12Dark() throws {
        try diff(in: "system:12", .dark)
    }

    func testTheDiffInSystem20Dark() throws {
        try diff(in: "system:20", .dark)
    }

    func testTheDiffInSourceCodePro12Dark() throws {
        try diff(in: "sourceCodePro:12", .dark)
    }

    func testTheDiffInJetBrainsMono16Dark() throws {
        try diff(in: "jetBrainsMono:16", .dark)
    }

    func testTheDiffInFiraCode9Dark() throws {
        try diff(in: "firaCode:9", .dark)
    }

    func testTheDiffInIbmPlexMono20Dark() throws {
        try diff(in: "ibmPlexMono:20", .dark)
    }

    func testTheDiffInMenlo12Dark() throws {
        try diff(in: "menlo:12", .dark)
    }

    func testTheDiffInCourierNew14Dark() throws {
        try diff(in: "courierNew:14", .dark)
    }

    /// The diff in `font`: the viewed mark is a 44 pt target, and a picture.
    private func diff(in font: String, _ appearance: XCUIDevice.Appearance) throws {
        openDiff(font: font, appearance: appearance)
        let viewed = app.buttons["file-viewed-0"]
        XCTAssertGreaterThanOrEqual(viewed.frame.width, 44, "\(font): the viewed mark's target")
        XCTAssertGreaterThanOrEqual(viewed.frame.height, 44, "\(font): the viewed mark's target")
        try recordScreenshot("diff-font-\(font.replacingOccurrences(of: ":", with: "-"))-\(name(appearance))")
    }

    /// The mark takes its own tap: the file doesn't fold under it, and nothing in the header moves. (Over these
    /// samples the Worker refuses the write, so the mark goes back to off.)
    func testTheViewedMarkTakesItsTapWithoutMovingTheHeader() {
        openDiff(font: "system:12", appearance: .light)
        let header = app.buttons["file-header-0"]
        let viewed = app.buttons["file-viewed-0"]
        let before = (header.frame, viewed.frame)
        viewed.tap()
        app.waitForStill(header)
        XCTAssertEqual(header.value as? String, "open", "the tap was the mark's, not the header's")
        XCTAssertEqual(header.frame, before.0)
        XCTAssertEqual(viewed.frame, before.1)
    }

    func testSettingsChangesAnOpenDiff() throws {
        // No font argument: it would override what Settings stores.
        openDiff(font: nil, appearance: .light)
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

    private func openDiff(font: String?, appearance: XCUIDevice.Appearance) {
        app.launch(["-PRHubPaired"] + (font.map { ["-prkit.diffFont", $0] } ?? []), appearance: appearance)
        let row = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // Files changed: the diff with its panel waiting, the code all there is.
        let diff = app.buttons["pr-files-changed"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-viewed-0"].waitForExistence(timeout: 5))
    }

    private func name(_ appearance: XCUIDevice.Appearance) -> String {
        appearance == .dark ? "dark" : "light"
    }
}
