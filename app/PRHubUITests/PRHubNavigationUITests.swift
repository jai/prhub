import XCTest

/// How a PR's diff is reached and left, over the sample PRs: Review changes pushes the diff over the PR, so Back returns
/// to the PR; a row's Review shortcut (its button, its swipe and its menu) and a link to a PR's files land on the diff
/// with the PR under it; the panel opens on Key lines, or on Files with no model. On a wide screen (an iPad) the list
/// sits beside the PR and a diff takes the whole width, with its panel as a column; a narrow Split View keeps the phone's
/// layout. Pictures go to `SCREENSHOTS_DIR` when it is set.
@MainActor
final class PRHubNavigationUITests: XCTestCase {
    private let app = XCUIApplication()
    private let checkout = "Show a retry button when checkout fails"
    private let checkoutRef = "acme/web#412"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testReviewChangesPushesTheDiffAndBackReturnsToThePR() {
        launch()
        openCheckout()
        app.buttons["pr-review-changes"].tap()
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5), "the diff")
        XCTAssertFalse(app.buttons["key-lines-context-100"].exists && !isWide, "the panel waits for its button")
        back()
        XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "Back from the diff is the PR")
        if !isWide {
            back()
            XCTAssertTrue(waitForHittable(app.staticTexts[checkout]), "and Back from the PR is the list")
        }
    }

    func testTheFilesChangedRowOpensTheDiffToo() {
        launch()
        openCheckout()
        app.buttons["pr-files-changed"].tap()
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
    }

    func testTheRowsReviewButtonLandsOnTheDiffWithKeyLinesOpenAndBackGoesToThePR() {
        launch()
        let review = app.buttons["pr-row-review-\(checkoutRef)"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        assertOnDiffWithKeyLinesOpen()
        backToThePRThenTheList()
    }

    func testSwipingARowRightOffersReviewChanges() {
        launch()
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        let review = app.buttons["pr-swipe-review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        try? picture("nav-swipe-review")
        review.tap()
        assertOnDiffWithKeyLinesOpen()
        backToThePRThenTheList()
    }

    func testARowsMenuOpensReviewsAndLinks() {
        launch()
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        for item in ["pr-menu-open", "pr-menu-review", "pr-menu-github", "pr-menu-copy"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), item)
        }
        try? picture("nav-row-menu")
        app.buttons["pr-menu-review"].tap()
        assertOnDiffWithKeyLinesOpen()
    }

    func testALinkToAPRsFilesOpensItsDiffWithThePRUnderIt() {
        launch(["-PRHubOpen", "https://github.com/acme/web/pull/412/files"])
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 10), "on the diff")
        back()
        XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "with the PR under it")
    }

    func testThePanelOpensOnKeyLinesAndOnFilesWhenTheWorkerHasNoModel() {
        launch()
        openCheckout()
        app.buttons["pr-review-changes"].tap()
        openPanel()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 3), "Key lines first")

        launch(["-PRHubNoAI"])
        openCheckout()
        app.buttons["pr-review-changes"].tap()
        openPanel()
        XCTAssertTrue(app.buttons["diff-changed-only"].waitForExistence(timeout: 3), "Files, with no key lines")
        XCTAssertFalse(app.buttons["key-lines-context-100"].exists)
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
            XCTAssertTrue(isBeside(listRow), "the list stays beside the PR")
            XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "not pushed over it")

            app.buttons["pr-review-changes"].tap()
            XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
            XCTAssertTrue(waitFor { !isBeside(listRow) }, "the diff takes the list's room")
            XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 3), "the panel is a column")
            try picture("nav-wide-diff-\(name)")
            let window = app.windows.firstMatch
            // The Simulator can drop the first hardware key after a launch.
            window.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])

            window.typeKey("0", modifierFlags: [.command, .option])
            XCTAssertTrue(waitFor { !app.buttons["key-lines-context-100"].exists }, "⌥⌘0 puts the panel away")
            window.typeKey("0", modifierFlags: [.command, .option])
            XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 3), "and brings it back")
            window.typeKey(.downArrow, modifierFlags: [.command, .option])

            back()
            XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "Back is the PR")
            XCTAssertTrue(waitFor { isBeside(listRow) }, "with the list beside it again")
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
        app.buttons["pr-review-changes"].tap()
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

    private func openPanel() {
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5))
        if !(isWide && app.buttons["key-lines-context-100"].exists || app.buttons["diff-changed-only"].exists) {
            app.buttons["diff-files"].tap()
        }
    }

    private func assertOnDiffWithKeyLinesOpen() {
        XCTAssertTrue(app.buttons["diff-files"].waitForExistence(timeout: 5), "on the diff")
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5), "with Key lines open")
    }

    private func backToThePRThenTheList() {
        if !isWide, app.buttons["key-lines-context-100"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        }
        back()
        XCTAssertTrue(waitForHittable(app.buttons["pr-review-changes"]), "Back from the diff is the PR")
        if !isWide {
            back()
            XCTAssertTrue(waitForHittable(app.staticTexts[checkout]), "then the list")
        }
    }

    private func back() {
        let button = app.navigationBars.buttons["BackButton"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    /// On screen, in the window's left half: the list's column.
    private func isBeside(_ row: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        return row.exists && row.frame.minX >= window.minX && row.frame.maxX < window.midX
    }

    private func waitForHittable(_ element: XCUIElement) -> Bool {
        waitFor { element.exists && element.isHittable }
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
        let look = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(look)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name)-\(look).png"))
    }
}
