import XCTest

/// Screenshot captures, not tests: the diff in each face and size Settings offers, light and dark, and a long path's
/// header at the default, XXXL and largest text sizes. What they show is checked below the UI: the viewed mark's
/// target is `DiffViewedMarkTests`', the header's path fit `DiffFileHeaderTests`'. Each launch is its own capture, so a
/// slow one fails alone. Run from `PRHubScreenshots.xctestplan`; pictures go to `SCREENSHOTS_DIR` when set.
@MainActor
final class PRHubDiffScreenshotTests: PRHubUITestCase {
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

    func testALongPathAtTheDefaultTextSize() throws {
        try longPath("default", textSize: nil)
    }

    func testALongPathAtXXXLText() throws {
        try longPath("xxxl", textSize: "UICTContentSizeCategoryXXXL")
    }

    func testALongPathInTheLargestText() throws {
        try longPath("largest", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    /// The checkout PR's Files changed in `font` (`-prkit.diffFont face:size`, as Settings stores it).
    private func diff(in font: String, _ appearance: XCUIDevice.Appearance) throws {
        app.launch(["-PRHubPaired", "-prkit.diffFont", font], appearance: appearance)
        app.openPR("Show a retry button when checkout fails")
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.buttons["file-viewed-0"].waitForExistence(timeout: 5))
        let look = appearance == .dark ? "dark" : "light"
        try recordScreenshot("diff-font-\(font.replacingOccurrences(of: ":", with: "-"))-\(look)")
    }

    /// The long-diff PR's header, its path as long as a phone's width allows.
    private func longPath(_ name: String, textSize: String?) throws {
        app.launch(
            ["-PRHubPaired", "-PRHubLongDiff", "-prhubAlertsDeclined", "YES"]
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: .light
        )
        app.openPR("Give the deploy team access to staging")
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(app.reveal(files), "Files changed, under the PR's summary")
        files.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 5))
        try recordScreenshot("diff-sideways-long-path-\(name)")
    }
}
