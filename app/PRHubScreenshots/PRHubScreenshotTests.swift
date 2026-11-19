import XCTest

/// Screenshot captures, not tests: nothing here compares a picture with anything. They wait for each screen and keep
/// its picture, for review and the App Store, and run from `PRHubScreenshots.xctestplan`, never the release gate.
/// Pictures of every screen in light, dark and the largest accessibility text, over the sample PRs: onboarding, the
/// list, a PR and its grouped checks, its diff with the panel open and on a key line under the review bar, and Settings; then Sign in with GitHub's screens over the fake hosted Worker:
/// onboarding with every way in, a refused sign-in, the account's Settings with and without a key, Delete Account,
/// Sign in again, the empty list, GitHub access and the empty list with the App on no account. Each is an attachment,
/// and a PNG in `SCREENSHOTS_DIR` when the run sets it (`TEST_RUNNER_SCREENSHOTS_DIR` on xcodebuild's command line).
@MainActor
final class PRHubScreenshotTests: PRHubUITestCase {
    private enum Look: String, CaseIterable {
        case light, dark, largeText = "large-text"
    }

    // One launch a test: each screen in each look is its own test. One walk of every screen a look took 19 minutes
    // on CI's iPad, and one slow screen failed the whole look.

    func testOnboardingInLight() throws {
        try onboarding(.light)
    }

    func testOnboardingInDark() throws {
        try onboarding(.dark)
    }

    func testOnboardingInLargeText() throws {
        try onboarding(.largeText)
    }

    func testTheSamplesWalkInLight() throws {
        try samplesWalk(.light)
    }

    func testTheSamplesWalkInDark() throws {
        try samplesWalk(.dark)
    }

    func testTheSamplesWalkInLargeText() throws {
        try samplesWalk(.largeText)
    }

    func testSettingsInLight() throws {
        try settings(.light)
    }

    func testSettingsInDark() throws {
        try settings(.dark)
    }

    func testSettingsInLargeText() throws {
        try settings(.largeText)
    }

    func testOnboardingEveryWayInInLight() throws {
        try onboardingEveryWayIn(.light)
    }

    func testOnboardingEveryWayInInDark() throws {
        try onboardingEveryWayIn(.dark)
    }

    func testOnboardingEveryWayInInLargeText() throws {
        try onboardingEveryWayIn(.largeText)
    }

    func testARefusedSignInInLight() throws {
        try signInRefused(.light)
    }

    func testARefusedSignInInDark() throws {
        try signInRefused(.dark)
    }

    func testARefusedSignInInLargeText() throws {
        try signInRefused(.largeText)
    }

    func testAnAccountWithAKeyInLight() throws {
        try accountKeySet(.light)
    }

    func testAnAccountWithAKeyInDark() throws {
        try accountKeySet(.dark)
    }

    func testAnAccountWithAKeyInLargeText() throws {
        try accountKeySet(.largeText)
    }

    func testAnAccountWithNoKeyAndDeleteAccountInLight() throws {
        try accountNoKey(.light)
    }

    func testAnAccountWithNoKeyAndDeleteAccountInDark() throws {
        try accountNoKey(.dark)
    }

    func testAnAccountWithNoKeyAndDeleteAccountInLargeText() throws {
        try accountNoKey(.largeText)
    }

    func testSignInAgainInLight() throws {
        try signInAgain(.light)
    }

    func testSignInAgainInDark() throws {
        try signInAgain(.dark)
    }

    func testSignInAgainInLargeText() throws {
        try signInAgain(.largeText)
    }

    func testTheEmptyListInLight() throws {
        try emptyList(.light)
    }

    func testTheEmptyListInDark() throws {
        try emptyList(.dark)
    }

    func testTheEmptyListInLargeText() throws {
        try emptyList(.largeText)
    }

    func testGitHubAccessInLight() throws {
        try githubAccess(.light)
    }

    func testGitHubAccessInDark() throws {
        try githubAccess(.dark)
    }

    func testGitHubAccessInLargeText() throws {
        try githubAccess(.largeText)
    }

    func testTheEmptyListOnNoAccountInLight() throws {
        try emptyListNotInstalled(.light)
    }

    func testTheEmptyListOnNoAccountInDark() throws {
        try emptyListNotInstalled(.dark)
    }

    func testTheEmptyListOnNoAccountInLargeText() throws {
        try emptyListNotInstalled(.largeText)
    }

    func testTheWideListInLight() throws {
        try wideList(.light)
    }

    func testTheWideListInDark() throws {
        try wideList(.dark)
    }

    func testTheWideListInLargeText() throws {
        try wideList(.largeText)
    }

    func testTheListUnderItsNotUpToDateLineInLight() throws {
        try listBanner(.light)
    }

    func testTheListUnderItsNotUpToDateLineInDark() throws {
        try listBanner(.dark)
    }

    func testTheListUnderItsNotUpToDateLineInLargeText() throws {
        try listBanner(.largeText)
    }

    private func launch(_ look: Look, _ arguments: [String]) {
        app.launch(
            arguments + (look == .largeText
                ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : []),
            appearance: look == .dark ? .dark : .light
        )
    }

    private func onboarding(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun"])
        XCTAssertTrue(app.buttons["onboardingSignIn"].waitForExistence(timeout: 10))
        try picture("1-onboarding", look)
    }

    /// The list, a PR and its grouped checks, its diff with the panel open, and on a key line under the review bar.
    private func samplesWalk(_ look: Look) throws {
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
        XCTAssertTrue(app.reveal(review), "Review changes is out from under the bars")
        review.tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5))
        try picture("4-diff-panel", look)
        app.closePanelOverDiff()
        XCTAssertTrue(app.buttons["key-line-next"].waitForExistence(timeout: 5))
        app.buttons["key-line-next"].tap()
        let note = app.descendants(matching: .any)["key-line-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        try picture("4-diff-key-line", look)
    }

    private func settings(_ look: Look) throws {
        launch(look, ["-PRHubPaired", "-PRHubSettings"])
        XCTAssertTrue(app.staticTexts["prhub-worker-host"].waitForExistence(timeout: 10)
            || app.descendants(matching: .any)["prhub-worker-host"].waitForExistence(timeout: 5))
        try picture("5-settings", look)
    }

    private func onboardingEveryWayIn(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun", "-PRHubSelfHosted", "YES"])
        let ownWorker = app.buttons["onboardingOwnWorker"]
        XCTAssertTrue(ownWorker.waitForExistence(timeout: 10))
        ownWorker.tap()
        XCTAssertTrue(app.buttons["onboardingScan"].waitForExistence(timeout: 5))
        try picture("6-onboarding-every-way-in", look)
    }

    private func signInRefused(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun", "-PRHubSignInDenied"])
        let signIn = app.buttons["onboardingSignIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        let refusal = app.descendants(matching: .any).matching(identifier: "onboardingStatus")
            .matching(NSPredicate(format: "label CONTAINS %@", "didn't authorize")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 5), "the refusal, not the in-progress sign-in message")
        try picture("7-sign-in-refused", look)
    }

    private func accountKeySet(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubSettings", "-PRHubAnthropicKey"])
        XCTAssertTrue(app.descendants(matching: .any)["prhub-account-login"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollSettings(to: app.descendants(matching: .any)["prhub-anthropic-key-set"]))
        try picture("8-account-key-set", look)
    }

    private func accountNoKey(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubSettings"])
        XCTAssertTrue(app.descendants(matching: .any)["prhub-account-login"].waitForExistence(timeout: 10))
        // In the largest text a swipe can step past the field to the foot of Settings: back down to it, then.
        let keyField = app.secureTextFields["prhub-anthropic-key-field"]
        XCTAssertTrue(app.scrollSettings(to: keyField) || app.scrollSettings(to: keyField, up: false))
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
    }

    private func signInAgain(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubSignedOut"])
        XCTAssertTrue(app.descendants(matching: .any)["signedOutReason"].waitForExistence(timeout: 10))
        try picture("12-sign-in-again", look)
    }

    /// The offer of review alerts comes first over the hosted list: the fake Worker pushes.
    private func declineAlertsOffer() {
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
    }

    private func emptyList(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubHostedEmpty"])
        declineAlertsOffer()
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].waitForExistence(timeout: 10))
        try picture("13-empty-list", look)
    }

    private func githubAccess(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubSettings"])
        let access = app.descendants(matching: .any)["github-access-add-account"]
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollSettings(to: access))
        try picture("14-github-access", look)
    }

    private func emptyListNotInstalled(_ look: Look) throws {
        launch(look, ["-PRHubHosted", "-PRHubHostedEmpty", "-PRHubInstallations", "none"])
        declineAlertsOffer()
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].waitForExistence(timeout: 10))
        try picture("15-empty-list-not-installed", look)
    }

    /// The list and a PR in landscape on both device types. The screenshot records their layout; the navigation
    /// suite separately asserts the iPad's side-by-side columns.
    private func wideList(_ look: Look) throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        launch(look, ["-PRHubPaired"])
        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        try picture("2-list-wide", look)
        checkout.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
        try picture("3-pr-wide", look)
    }

    /// The list under its "Not up to date" line. Jai saw the pull-to-refresh spinner and the line's words on top of
    /// each other (2026-11-14); no synthesized pull refreshes the list in a UI test (three kinds tried, on both
    /// devices), so that state is not pictured here.
    private func listBanner(_ look: Look) throws {
        launch(look, ["-PRHubPaired", "-PRHubNotUpToDate"])
        XCTAssertTrue(app.staticTexts["Show a retry button when checkout fails"].waitForExistence(timeout: 10))
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Not up to date'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        try picture("2-list-banner", look)
    }

    private func picture(_ step: String, _ look: Look) throws {
        try recordScreenshot("\(step)-\(look.rawValue)")
    }
}
