import XCTest

/// How a PR's diff is reached and left, over the sample PRs: Review changes pushes the diff over the PR with its panel
/// open on Key lines, so Back returns to the PR; a row's swipe and its menu land on the diff with the PR under it. On a
/// wide screen (an iPad) the list sits beside the PR and a diff takes the whole width, with its panel as a column; a
/// narrow Split View keeps the phone's layout. Where each way in lands is PRKit's `PRNavigationTests`. Pictures stay in the test's result bundle.
@MainActor
final class PRKitNavigationUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"
    private let checkoutRef = "acme/web#412"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    func testReviewChangesPushesTheDiffWithKeyLinesOpenAndBackReturnsToThePR() throws {
        launch()
        openCheckout()
        app.buttons["pr-review-changes"].tap()
        assertOnDiffWithKeyLinesOpen()
        try picture("nav-review-changes-panel")
        backToThePRThenTheList()
    }

    /// The diff sends a review the way the PR's page does: the bar under the code, its box in the bar's place. Sent, it
    /// leaves the diff and its PR for the list, where the toast follows it under the nav bar (Jai's feedback, build 305).
    func testTheDiffHasTheReviewBarAndSendsAReview() throws {
        launch()
        openCheckout()
        app.buttons["pr-files-changed"].tap()
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
        for action in ["pr-review-approve", "pr-review-request-changes", "pr-review-comment"] {
            XCTAssertTrue(waitForHittable(app.buttons[action]), action)
        }
        XCTAssertEqual(app.buttons["pr-review-request-changes"].label, "Request changes")
        let widths = ["pr-review-approve", "pr-review-request-changes", "pr-review-comment"]
            .map { app.buttons[$0].frame.width }
        XCTAssertEqual(try XCTUnwrap(widths.max()) - XCTUnwrap(widths.min()), 0, accuracy: 1, "one bar of equal buttons")
        try picture("nav-diff-review-bar")
        let approve = app.buttons["pr-review-approve"]
        let approveLeft = approve.frame.minX
        approve.tap()
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.frame.minX, approveLeft, accuracy: 1, "Approve stays on the left when its box opens")
        XCTAssertLessThan(send.frame.maxX, app.buttons["Cancel"].frame.minX)
        try picture("nav-diff-approve-open")
        XCTAssertFalse(app.buttons["pr-review-approve"].exists, "the box takes the bar's place")
        send.tap()
        XCTAssertTrue(waitFor { !app.buttons["diff-files"].exists }, "the review leaves the diff")
        XCTAssertTrue(app.staticTexts[checkout].waitForExistence(timeout: 5), "for the list")
        XCTAssertFalse(app.buttons["pr-review-changes"].exists, "not the PR")
        let toast = app.descendants(matching: .any)["pr-review-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "the toast follows the review on the list")
        let bar = app.navigationBars.firstMatch
        XCTAssertGreaterThanOrEqual(toast.frame.minY, bar.frame.maxY - 1, "under the nav bar, never over Back")
        let words = app.descendants(matching: .any)["pr-review-toast-words"]
        XCTAssertTrue(waitFor(timeout: 10) { words.label == "Approved" }, "and says it landed")
        try picture("nav-diff-review-sent-list")
    }

    func testSwipingARowRightOffersReviewChanges() throws {
        launch()
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        let review = app.buttons["pr-swipe-review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        try picture("nav-swipe-review")
        review.tap()
        assertOnDiffWithKeyLinesOpen()
        backToThePRThenTheList()
    }

    func testARowsMenuOpensReviewsAndLinks() throws {
        launch()
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        for item in ["pr-menu-open", "pr-menu-review", "pr-menu-github", "pr-menu-copy"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), item)
        }
        try picture("nav-row-menu")
        app.buttons["pr-menu-review"].tap()
        assertOnDiffWithKeyLinesOpen()
    }

    /// The wide layout in each orientation: the PR beside the list, then the diff across the width with its panel as a
    /// column, the keyboard's shortcuts, and Back to the list beside the PR.
    func testOnAWideScreenInPortrait() throws {
        try wideLayout(.portrait)
    }

    func testOnAWideScreenInLandscape() throws {
        XCUIDevice.shared.appearance = .dark
        try wideLayout(.landscapeLeft)
    }

    /// One launch each: a second launch in the same test gets no hardware keys.
    private func wideLayout(_ orientation: UIDeviceOrientation) throws {
        do {
            XCUIDevice.shared.orientation = orientation
            launch()
            try XCTSkipUnless(isWide, "a regular width only")
            let name = orientation == .portrait ? "portrait" : "landscape"
            let row = app.staticTexts[checkout]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]))
            try picture("nav-wide-pr-\(name)")
            let listRow = app.buttons["pr-row-review-\(checkoutRef)"]
            XCTAssertTrue(waitFor { [self] in isBeside(listRow) }, "the list stays beside the PR")
            XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "not pushed over it")

            app.buttons["pr-review-changes"].tap()
            XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
            XCTAssertTrue(waitFor { [self] in !isBeside(listRow) }, "the diff takes the list's room")
            XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 3), "the panel is a column")
            try picture("nav-wide-diff-\(name)")
            let window = app.windows.firstMatch
            // The Simulator can drop the first hardware key after a launch.
            window.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])

            window.typeKey("0", modifierFlags: [.command, .option])
            XCTAssertTrue(waitFor { [self] in !app.buttons["key-lines-context-100"].exists }, "⌥⌘0 puts the panel away")
            window.typeKey("0", modifierFlags: [.command, .option])
            XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 3), "and brings it back")
            window.typeKey(.downArrow, modifierFlags: [.command, .option])

            app.back()
            XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "Back is the PR")
            XCTAssertTrue(waitFor { [self] in isBeside(listRow) }, "with the list beside it again")
        }
    }

    /// A narrow Split View or Slide Over is a compact width: the phone's stack, on any screen.
    func testANarrowSplitViewKeepsThePhonesStack() throws {
        XCUIDevice.shared.appearance = .dark
        launch(["-PRHubCompactWidth"])
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]))
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 3), "pushed over the list")
        app.buttons["pr-files-changed"].tap()
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
        try picture("nav-compact-diff")
        XCTAssertFalse(app.buttons["key-lines-context-100"].exists, "the panel is over the diff, shut")
        backToThePRThenTheList()
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = []) {
        app.terminate()
        app.launchArguments = ["-PRHubPaired"] + arguments
        app.launch()
    }

    /// The PRs tab lays out side by side: the list's row is still on screen with a PR open.
    private var isWide: Bool {
        app.windows.firstMatch.horizontalSizeClass == .regular
            && !app.launchArguments.contains("-PRHubCompactWidth")
    }

    private func openCheckout() {
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
    }

    private func assertOnDiffWithKeyLinesOpen() {
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5), "on the diff")
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5), "with Key lines open")
    }

    private func backToThePRThenTheList() {
        if !isWide, app.buttons["key-lines-context-100"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        }
        app.back()
        XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "Back from the diff is the PR")
        if !isWide {
            app.back()
            XCTAssertTrue(waitForHittable(app.staticTexts[checkout]), "then the list")
        }
    }

    /// On screen, in the window's left half: the list's column.
    /// Read from one snapshot: the list can replace its rows while the PR opens. The caller's predicate retries
    /// a stale snapshot instead of nesting another waiter or querying exists and frame from different snapshots.
    private func isBeside(_ row: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        guard let frame = try? row.snapshot().frame else {
            return false
        }
        return frame.minX >= window.minX && frame.maxX < window.midX
    }

    private func waitForHittable(_ element: XCUIElement) -> Bool {
        waitFor { element.exists && element.isHittable }
    }

    private func picture(_ name: String) throws {
        let look = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        recordScreenshot("\(name)-\(look)")
    }
}
