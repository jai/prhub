import XCTest

/// Pictures of every screen in light, dark and the largest accessibility text, over the sample PRs: onboarding, the
/// list, a PR and its grouped checks, its diff with the panel open and on a key line under the review bar, and Settings; then Sign in with GitHub's screens over the fake hosted Worker:
/// onboarding with every way in, a refused sign-in, the account's Settings with and without a key, Delete Account,
/// Sign in again, the empty list, GitHub access and the empty list with the App on no account. Each is an attachment,
/// and a PNG in `SCREENSHOTS_DIR` when the run sets it (`TEST_RUNNER_SCREENSHOTS_DIR` on xcodebuild's command line).
@MainActor
final class PRHubScreenshotTests: XCTestCase {
    private enum Look: String, CaseIterable {
        case light, dark, largeText = "large-text"
    }

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryScreenInEveryLook() throws {
        for look in Look.allCases {
            try pictures(look)
        }
    }

    func testWideListSeparationInEveryLook() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        for look in Look.allCases {
            launch(look, ["-PRHubPaired"])
            let checkout = app.staticTexts["Show a retry button when checkout fails"]
            XCTAssertTrue(checkout.waitForExistence(timeout: 10))
            try picture("2-list-wide", look)
            checkout.tap()
            XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
            try picture("3-pr-wide", look)
        }
    }

    /// The list under its "Not up to date" line, at rest and while a pull to refresh runs: Jai saw the spinner and the
    /// line's words on top of each other (2026-11-14). Pictures only, until they show what is wrong.
    func testListRefreshingUnderItsBannerInEveryLook() throws {
        for look in Look.allCases {
            launch(look, ["-PRHubPaired", "-PRHubSlowRefresh"])
            let checkout = app.staticTexts["Show a retry button when checkout fails"]
            XCTAssertTrue(checkout.waitForExistence(timeout: 10))
            try picture("2-list-banner", look)
            // From the line itself, which takes no tap, slowly, and held past the pull's length before letting go: the
            // first try dragged a row fast and nothing refreshed.
            let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Not up to date'")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 5))
            let from = line.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(
                forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 320)), withVelocity: .slow,
                thenHoldForDuration: 0.8
            )
            RunLoop.current.run(until: Date.now.addingTimeInterval(1))
            try picture("2-list-refreshing", look)
        }
    }

    private func launch(_ look: Look, _ arguments: [String]) {
        app.launch(
            arguments + (look == .largeText
                ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : []),
            appearance: look == .dark ? .dark : .light
        )
    }

    private func pictures(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun"])
        XCTAssertTrue(app.buttons["onboardingSignIn"].waitForExistence(timeout: 10))
        try picture("1-onboarding", look)

        launch(look, ["-PRHubPaired"])
        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        try picture("2-list", look)
        checkout.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
        try picture("3-pr", look)
        app.buttons["checks-header"].tap()
        let group = app.buttons["check-group-visual proof"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        if !group.isHittable {
            app.swipeUp(velocity: .slow)
        }
        group.tap()
        XCTAssertTrue(app.buttons["web 1/4"].waitForExistence(timeout: 5))
        try picture("3-pr-checks", look)
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(app.scrollDown(to: review), "Review changes is out from under the bars")
        review.tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5))
        try picture("4-diff-panel", look)
        app.closePanelOverDiff()
        XCTAssertTrue(app.buttons["key-line-next"].waitForExistence(timeout: 5))
        app.buttons["key-line-next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))
        try picture("4-diff-key-line", look)

        launch(look, ["-PRHubPaired", "-PRHubSettings"])
        XCTAssertTrue(app.staticTexts["prhub-worker-host"].waitForExistence(timeout: 10)
            || app.descendants(matching: .any)["prhub-worker-host"].waitForExistence(timeout: 5))
        try picture("5-settings", look)

        try hostedPictures(look)
    }

    private func hostedPictures(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun", "-PRHubSelfHosted", "YES"])
        let ownWorker = app.buttons["onboardingOwnWorker"]
        XCTAssertTrue(ownWorker.waitForExistence(timeout: 10))
        ownWorker.tap()
        XCTAssertTrue(app.buttons["onboardingScan"].waitForExistence(timeout: 5))
        try picture("6-onboarding-every-way-in", look)

        launch(look, ["-PRHubFirstRun", "-PRHubSignInDenied"])
        app.buttons["onboardingSignIn"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboardingStatus"].waitForExistence(timeout: 5))
        try picture("7-sign-in-refused", look)

        launch(look, ["-PRHubHosted", "-PRHubSettings", "-PRHubAnthropicKey"])
        XCTAssertTrue(app.descendants(matching: .any)["prhub-account-login"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollSettings(to: app.descendants(matching: .any)["prhub-anthropic-key-set"]))
        try picture("8-account-key-set", look)

        launch(look, ["-PRHubHosted", "-PRHubSettings"])
        XCTAssertTrue(app.descendants(matching: .any)["prhub-account-login"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollSettings(to: app.secureTextFields["prhub-anthropic-key-field"]))
        try picture("9-account-no-key", look)
        let delete = app.buttons["prhub-delete-account"]
        XCTAssertTrue(app.scrollSettings(to: delete))
        app.scrollViews["prhub-settings"].swipeUp()
        try picture("10-account-bottom", look)
        // The diff font's section sits under it, so the bottom of Settings can be past the button.
        XCTAssertTrue(app.scrollSettings(to: delete, up: false))
        delete.tap()
        XCTAssertTrue(app.buttons["prhub-delete-account-confirm"].waitForExistence(timeout: 5))
        try picture("11-delete-account", look)

        launch(look, ["-PRHubHosted", "-PRHubSignedOut"])
        XCTAssertTrue(app.descendants(matching: .any)["signedOutReason"].waitForExistence(timeout: 10))
        try picture("12-sign-in-again", look)

        launch(look, ["-PRHubHosted", "-PRHubHostedEmpty"])
        // The offer of review alerts comes first: the fake Worker pushes.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].waitForExistence(timeout: 10))
        try picture("13-empty-list", look)

        launch(look, ["-PRHubHosted", "-PRHubSettings"])
        let access = app.descendants(matching: .any)["github-access-add-account"]
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollSettings(to: access))
        try picture("14-github-access", look)

        launch(look, ["-PRHubHosted", "-PRHubHostedEmpty", "-PRHubInstallations", "none"])
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].waitForExistence(timeout: 10))
        try picture("15-empty-list-not-installed", look)
    }

    private func picture(_ step: String, _ look: Look) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(step)-\(look.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(step)-\(look.rawValue).png"))
    }
}
