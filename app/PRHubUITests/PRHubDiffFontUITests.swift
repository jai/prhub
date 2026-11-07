import XCTest

/// The diff's font: pictures of the diff at small, default and large sizes in several faces, light and dark; the
/// viewed mark is a 44 pt target at every size; and a change in Settings redraws a diff that is already open. Over the
/// sample PRs, with the font set the way Settings stores it (`-prkit.diffFont face:size`). Pictures go to
/// `SCREENSHOTS_DIR` when set.
@MainActor
final class PRHubDiffFontUITests: XCTestCase {
    private static let fonts = [
        "system:9", "system:12", "system:20", "sourceCodePro:12", "jetBrainsMono:16", "firaCode:9",
        "ibmPlexMono:20", "menlo:12", "courierNew:14",
    ]

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheDiffInEveryFontAndSize() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            for font in Self.fonts {
                openDiff(font: font, appearance: appearance)
                let viewed = app.buttons["file-viewed-0"]
                XCTAssertGreaterThanOrEqual(viewed.frame.width, 44, "\(font): the viewed mark's target")
                XCTAssertGreaterThanOrEqual(viewed.frame.height, 44, "\(font): the viewed mark's target")
                try picture("diff-font-\(font.replacingOccurrences(of: ":", with: "-"))-\(name(appearance))")
            }
        }
    }

    /// The mark takes its own tap: the file doesn't fold under it, and nothing in the header moves. (Over these
    /// samples the Worker refuses the write, so the mark goes back to off.)
    func testTheViewedMarkTakesItsTapWithoutMovingTheHeader() throws {
        openDiff(font: "system:12", appearance: .light)
        let header = app.buttons["file-header-0"]
        let viewed = app.buttons["file-viewed-0"]
        let before = (header.frame, viewed.frame)
        viewed.tap()
        RunLoop.current.run(until: Date.now.addingTimeInterval(1))
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

        app.tabBars.buttons["Settings"].tap()
        let preview = app.descendants(matching: .any)["diff-font-preview"]
        XCTAssertTrue(app.scrollSettings(to: preview))
        try picture("diff-font-settings-before")
        let bigger = app.descendants(matching: .any)["diff-font-size"].buttons["Bigger"]
        for _ in 0..<4 {
            bigger.tap()
        }
        let face = app.buttons["diff-font-jetBrainsMono"]
        XCTAssertTrue(app.scrollSettings(to: face))
        face.tap()
        XCTAssertTrue(app.scrollSettings(to: preview, up: false))
        try picture("diff-font-settings-after")

        app.tabBars.buttons["PRs"].tap()
        XCTAssertTrue(waitFor { line.exists && line.frame.height > before }, "the open diff redrew at 16 pt")
        try picture("diff-font-live-update")
    }

    private func openDiff(font: String?, appearance: XCUIDevice.Appearance) {
        app.launch(["-PRHubPaired"] + (font.map { ["-prkit.diffFont", $0] } ?? []), appearance: appearance)
        let row = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let diff = app.buttons["Diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-viewed-0"].waitForExistence(timeout: 5))
    }

    private func name(_ appearance: XCUIDevice.Appearance) -> String {
        appearance == .dark ? "dark" : "light"
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        return condition()
    }

    private func picture(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }
}
