import XCTest

/// "Try with sample PRs" as App Review meets it, with no Worker: onboarding, both lists, a PR's description and diff
/// with its key lines, an approval that stays on the phone, and Settings' way back to onboarding.
@MainActor
final class PRHubSamplesUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    func testTheSamplesWorkWithNoWorker() throws {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()

        let trySamples = app.buttons["onboardingTrySamples"]
        XCTAssertTrue(trySamples.waitForExistence(timeout: 10))
        trySamples.tap()

        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 5))
        app.segmentedControls["pr-list-page"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Add a fish shell prompt"].waitForExistence(timeout: 5))
        app.segmentedControls["pr-list-page"].buttons.element(boundBy: 0).tap()

        XCTAssertTrue(checkout.waitForExistence(timeout: 5))
        checkout.tap()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))

        app.buttons["pr-review-changes"].tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5), "the panel open on Key lines")
        app.closePanelOverDiff()
        XCTAssertTrue(app.buttons["key-line-position"].waitForExistence(timeout: 5))
        app.buttons["key-line-next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))

        app.back()
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let notice = app.staticTexts["pr-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Nothing was sent to GitHub"))

        app.go(to: .settings)
        let connect = app.buttons["prhub-connect-own-worker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        // The sign-in itself, in one tap: no stop at onboarding for a second Sign in with GitHub.
        XCTAssertTrue(waitFor { !connect.exists }, "signed in, the samples are over")
        XCTAssertFalse(app.buttons["onboardingSignIn"].exists, "and onboarding never showed")
        XCTAssertFalse(app.staticTexts["prhub-samples-explained"].exists)
    }

    /// The 2026-11-10 bug bash: a sign-in refused from the samples left him at onboarding, and what he had done to the
    /// samples was gone when he came back to them.
    func testASignInRefusedFromTheSamplesLeavesThemAsTheyWereAndSaysWhy() {
        app.launchArguments = ["-PRHubFirstRun", "-PRHubSignInDenied"]
        app.launch()
        let trySamples = app.buttons["onboardingTrySamples"]
        XCTAssertTrue(trySamples.waitForExistence(timeout: 10))
        trySamples.tap()
        app.go(to: .settings)
        let connect = app.buttons["prhub-connect-own-worker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let problem = app.descendants(matching: .any)["prhub-samples-sign-in-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "GitHub's refusal is said under the button")
        XCTAssertTrue(connect.exists, "still in the samples' Settings")
        XCTAssertTrue(app.staticTexts["prhub-samples-explained"].exists)
        XCTAssertFalse(app.buttons["onboardingSignIn"].exists)
    }

    /// Settings' switch for anonymous usage data: on until turned off, in a build that names an analytics project.
    func testSettingsOffersToStopSharingUsage() {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()
        let trySamples = app.buttons["onboardingTrySamples"]
        XCTAssertTrue(trySamples.waitForExistence(timeout: 10))
        trySamples.tap()
        app.go(to: .settings)
        let share = app.switches["prhub-share-usage"]
        XCTAssertTrue(app.scrollSettings(to: share))
        XCTAssertEqual(share.value as? String, "1")
    }

    /// In a build that pairs with self-hosted Workers (`PRHUB_SELF_HOSTED`), which this build is not.
    func testAPairingCodeThatIsRefusedSaysSo() {
        app.launchArguments = ["-PRHubFirstRun", "-PRHubSelfHosted", "YES", "-PRHubSignInWithGitHub", "NO"]
        app.launch()
        let field = app.textFields["onboardingLinkField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("prhub://setup?worker=https%3A%2F%2Fpr-review.example.workers.dev&code=7KQ2M9XA")
        app.buttons["onboardingConnect"].tap()
        let status = app.descendants(matching: .any)["onboardingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("expired"), status.label)
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
}
