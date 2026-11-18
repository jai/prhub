import XCTest

/// Another app hands off a PR, including its diff, to the current PRHub environment.
@MainActor
final class PRHubOpenLinkUITests: PRHubUITestCase {
    func testAHandoffFromSettingsOpensTheRequestedPR() throws {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
        app.go(to: .settings)
        try XCUIDevice.shared.system.open(handoff("https://github.com/acme/web/pull/412"))

        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["acme/web#412"].exists, "the requested PR's detail, not its list row")
        try recordScreenshot("handoff-requested-pr")
    }

    func testADiffHandoffKeepsTheSamplesOpen() throws {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()
        let samples = app.buttons["onboardingTrySamples"]
        XCTAssertTrue(samples.waitForExistence(timeout: 10))
        samples.tap()
        app.go(to: .settings)
        // `app.open` launches a fresh process and loses samples; a real app's handoff goes through the OS.
        try XCUIDevice.shared.system.open(handoff("https://github.com/acme/web/pull/412/files?w=1#diff-abcR12"))

        XCTAssertFalse(app.buttons["onboardingSignIn"].exists, "the handoff keeps the current samples")
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 10), "the requested PR's diff")
        try recordScreenshot("handoff-sample-diff")
    }

    private func handoff(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try XCTUnwrap(parts.url)
    }
}
