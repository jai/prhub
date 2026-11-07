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
        XCTAssertTrue(app.buttons["key-line-position"].waitForExistence(timeout: 5))
        app.buttons["key-line-next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let notice = app.staticTexts["pr-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Nothing was sent to GitHub"))

        app.tabBars.buttons["Settings"].tap()
        let connect = app.buttons["prhub-connect-own-worker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.buttons["onboardingSignIn"].waitForExistence(timeout: 5), "back on onboarding")
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
}
