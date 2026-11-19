import XCTest

/// "Try with sample PRs" as App Review meets it, with no Worker: onboarding, both lists, a PR's description and diff
/// with its key lines, an approval that stays on the phone, and Settings' way back to onboarding.
@MainActor
final class PRHubSamplesUITests: PRHubUITestCase {
    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
    }

    func testTheSamplesWorkWithNoWorker() {
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
}
