import XCTest

/// The diff's panel, on the sample PRs: the last key line scrolls up clear of the phone's tab bar and takes a tap
/// there, its tick sits at the row's start with Explain at the far end, its path has a line to itself, and the Files
/// page's foot is clear of the tab bar too. In light and dark, at the default text size and the largest.
@MainActor
final class PRKitKeyLinesPanelUITests: PRHubUITestCase {
    private static let noAlertsOffer = ["-prhubAlertsDeclined", "YES"]
    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"
    /// The checkout sample's last key line.
    private static let last = "src/checkout/payments.ts:RIGHT:12"

    func testTheLastKeyLineIsClearOfTheTabBar() throws {
        try lastKeyLine("light", appearance: .light, textSize: nil)
    }

    func testTheLastKeyLineIsClearOfTheTabBarInDark() throws {
        try lastKeyLine("dark", appearance: .dark, textSize: nil)
    }

    func testTheLastKeyLineIsClearOfTheTabBarInTheLargestText() throws {
        try lastKeyLine("largest-light", appearance: .light, textSize: Self.largest)
    }

    func testTheLastKeyLineIsClearOfTheTabBarInTheLargestTextInDark() throws {
        try lastKeyLine("largest-dark", appearance: .dark, textSize: Self.largest)
    }

    func testTheFilesFootIsClearOfTheTabBar() throws {
        try openPanel(appearance: .dark, textSize: nil)
        app.segmentedControls.buttons["Files"].tap()
        let foot = app.staticTexts["diff-summary"]
        XCTAssertTrue(foot.waitForExistence(timeout: 5))
        recordScreenshot("panel-files-dark")
        XCTAssertLessThanOrEqual(foot.frame.maxY, bottom, "the Files page's last line is above the tab bar")
        XCTAssertTrue(app.buttons["diff-changed-only"].isHittable)
    }

    private func lastKeyLine(_ name: String, appearance: XCUIDevice.Appearance, textSize: String?) throws {
        try openPanel(appearance: appearance, textSize: textSize)
        recordScreenshot("panel-key-lines-\(name)-1-top")

        let row = app.buttons["key-line-\(Self.last)"]
        let tick = app.buttons["key-line-reviewed-\(Self.last)"]
        let explain = app.buttons["key-line-explain-\(Self.last)"]
        let context = app.buttons["key-lines-context-100"]
        // Up to the list's end: until a drag moves nothing.
        let finger = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: context.frame.midX, dy: app.windows.firstMatch.frame.height * 0.6))
        var place = CGRect.null
        for _ in 0 ..< 40 where !row.exists || row.frame != place {
            place = row.exists ? row.frame : .null
            finger.press(
                forDuration: 0.05, thenDragTo: finger.withOffset(CGVector(dx: 0, dy: -400)), withVelocity: .fast,
                thenHoldForDuration: 0.2
            )
            if row.exists {
                app.waitForStill(row)
            }
        }
        recordScreenshot("panel-key-lines-\(name)-2-end")

        XCTAssertTrue(row.exists, "the last key line")
        XCTAssertLessThanOrEqual(row.frame.maxY, bottom, "\(name): the last key line's words end above the tab bar")
        XCTAssertTrue(tick.isHittable, "\(name): its tick takes a tap")
        XCTAssertLessThan(tick.frame.midX, row.frame.midX, "\(name): the tick is at the row's start, as in Files")
        XCTAssertGreaterThanOrEqual(tick.frame.width, 44)
        XCTAssertGreaterThanOrEqual(tick.frame.height, 44)
        if explain.exists {
            XCTAssertGreaterThan(explain.frame.minX, row.frame.midX, "\(name): Explain is at the far end")
            XCTAssertGreaterThanOrEqual(explain.frame.minX - tick.frame.maxX, 44, "\(name): and well away from the tick")
        }

        tick.tap()
        XCTAssertTrue(waitFor { tick.value as? String == "checked" }, "\(name): a tap there ticks it")
        XCTAssertEqual(app.staticTexts["key-lines-reviewed-count"].label, "1 of 2 reviewed")
        recordScreenshot("panel-key-lines-\(name)-3-ticked")
    }

    /// The checkout sample's diff, its panel open on Key lines.
    private func openPanel(appearance: XCUIDevice.Appearance, textSize: String?) throws {
        app.launch(
            ["-PRHubPaired"] + Self.noAlertsOffer
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: appearance
        )
        app.openPR("Show a retry button when checkout fails")
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(app.reveal(review), "Review changes, under the PR's summary")
        review.tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5), "the panel open on Key lines")
    }

    /// Where the panel's own room ends: the tab bar's top on a phone, the window's foot where the tabs are at the top.
    private var bottom: CGFloat {
        let window = app.windows.firstMatch
        guard window.horizontalSizeClass != .regular else {
            return window.frame.maxY
        }
        let tabBar = app.tabBars.firstMatch
        return tabBar.exists ? tabBar.frame.minY : window.frame.maxY
    }
}
