import XCTest

/// The diff's nav bar and tab bar leave as you scroll down a long file, and nothing can leave them gone with no way out:
/// folding the file brings them back, so does the status bar, and the edge swipe goes back to the PR while they are gone. On
/// `-PRHubLongDiff`, whose first PR has one file longer than the screen. Pictures go to `SCREENSHOTS_DIR` when set.
@MainActor
final class PRHubDiffBarsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testFoldingTheOnlyFileBringsTheBarsBack() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            let look = appearance == .dark ? "dark" : "light"
            openLongDiff(appearance)
            hideBars()
            try picture("diffbars-1-hidden-\(look)")

            app.buttons["file-header-0"].tap()
            XCTAssertEqual(app.buttons["file-header-0"].value as? String, "collapsed")
            waitForBars(shown: true, "folding the only file leaves nothing to scroll")
            try picture("diffbars-2-folded-\(look)")

            app.buttons["file-header-0"].tap()
            waitForBars(shown: true, "opening it again keeps them")
        }
    }

    func testTheStatusBarBringsTheBarsBack() {
        openLongDiff(.light)
        hideBars()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        waitForBars(shown: true, "a tap on the status bar goes to the top")
    }

    func testTheEdgeSwipeGoesBackWhileTheBarsAreHidden() {
        openLongDiff(.light)
        hideBars()
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(waitFor { review.exists && review.isHittable }, "back on the PR, not the list")
    }

    private func openLongDiff(_ appearance: XCUIDevice.Appearance) {
        app.launch(["-PRHubPaired", "-PRHubLongDiff"], appearance: appearance)
        let row = app.staticTexts["Give the deploy team access to staging"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let diff = app.buttons["pr-review-changes"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 5))
        waitForBars(shown: true, "the diff opens with its bars")
    }

    private func hideBars() {
        app.tables.firstMatch.swipeUp(velocity: .slow)
        waitForBars(shown: false, "scrolling down the code hides the bars")
    }

    /// The tab bar stands for both: they leave and come back together.
    private func waitForBars(shown: Bool, _ message: String) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(waitFor { (settings.exists && settings.isHittable) == shown }, message)
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
