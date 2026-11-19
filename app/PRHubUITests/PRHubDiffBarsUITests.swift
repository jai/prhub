import XCTest

/// The diff's nav bar and tab bar leave as you scroll down a long file, and nothing can leave them gone with no way out:
/// the status bar brings them back, and the edge swipe goes back to the PR while they are gone (when they leave and
/// come back is PRKit's `DiffBarsTests`). On
/// `-PRHubLongDiff`, whose first PR has one file longer than the screen.
@MainActor
final class PRHubDiffBarsUITests: PRHubUITestCase {
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
        // Files changed: the diff with its panel waiting, the code all there is.
        let diff = app.buttons["pr-files-changed"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 5))
        waitForBars(shown: true, "the diff opens with its bars")
    }

    private func hideBars() {
        app.tables.firstMatch.swipeUp(velocity: .slow)
        waitForBars(shown: false, "scrolling down the code hides the bars")
    }

    /// The Settings tab stands for both bars, a phone's tab bar or an iPad's tabs at the top: they leave and come back
    /// together.
    private func waitForBars(shown: Bool, _ message: String) {
        let settings = app.tab(.settings)
        XCTAssertTrue(waitFor { (settings.exists && settings.isHittable) == shown }, message)
    }
}
