import XCTest

/// The diff's panel under the phone's real tab bar, on the sample PRs, in dark as in Jai's picture (2026-11-25: the
/// last key line was overlapped by the tab bar). One walk: the last key line scrolls up clear of the tab bar and its
/// tick takes a tap there, then the Files page's foot is clear of it too. What needs the app is the tab bar itself:
/// the room it leaves the panel, and a tap that lands on the tick and not on the bar. The panel's layout under a bar,
/// in light and dark and the largest text, is `PRKeyLinesPanelRenderingTests`'; a key line's own layout is
/// `PRKeyLineRowRenderingTests`'.
@MainActor
final class PRKitKeyLinesPanelUITests: PRHubUITestCase {
    /// The checkout sample's last key line.
    private static let last = "src/checkout/payments.ts:RIGHT:12"

    func testTheLastKeyLineAndTheFilesFootAreClearOfTheTabBar() {
        app.launch(["-PRHubPaired", "-prhubAlertsDeclined", "YES"], appearance: .dark)
        app.openPR("Show a retry button when checkout fails")
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(app.reveal(review), "Review changes, under the PR's summary")
        review.tap()
        let context = app.buttons["key-lines-context-100"]
        XCTAssertTrue(context.waitForExistence(timeout: 5), "the panel open on Key lines")

        let row = app.buttons["key-line-\(Self.last)"]
        let tick = app.buttons["key-line-reviewed-\(Self.last)"]
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
        XCTAssertTrue(row.exists, "the last key line")
        XCTAssertLessThanOrEqual(row.frame.maxY, bottom, "the last key line's words end above the tab bar")
        XCTAssertTrue(tick.isHittable, "its tick takes a tap")
        tick.tap()
        XCTAssertTrue(waitFor { tick.value as? String == "checked" }, "a tap there ticks it")
        XCTAssertEqual(app.staticTexts["key-lines-reviewed-count"].label, "1 of 2 reviewed")

        app.segmentedControls.buttons["Files"].tap()
        let foot = app.staticTexts["diff-summary"]
        XCTAssertTrue(foot.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(foot.frame.maxY, bottom, "the Files page's last line is above the tab bar")
        XCTAssertTrue(app.buttons["diff-changed-only"].isHittable)
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
