import XCTest

/// Another app hands off a PR, including its diff, to the current PRHub environment.
@MainActor
final class PRHubOpenLinkUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testAHandoffFromSettingsOpensTheRequestedPR() throws {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
        app.go(to: .settings)
        app.open(try handoff("https://github.com/acme/web/pull/412"))

        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Show a retry button when checkout fails"].exists)
    }

    func testADiffHandoffKeepsTheSamplesOpen() throws {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()
        let samples = app.buttons["onboardingTrySamples"]
        XCTAssertTrue(samples.waitForExistence(timeout: 10))
        samples.tap()
        app.go(to: .settings)
        app.open(try handoff("https://github.com/acme/web/pull/412/files?w=1#diff-abcR12"))

        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 10), "the requested PR's diff")
        XCTAssertFalse(app.buttons["onboardingSignIn"].exists, "the handoff keeps the current samples")
    }

    private func handoff(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try XCTUnwrap(parts.url)
    }
}
