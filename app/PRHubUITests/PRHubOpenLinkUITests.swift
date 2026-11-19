import XCTest

/// Another app hands off a PR through the system to the current PRHub environment. Where a handoff lands, the samples
/// included, is `OpenLinkEnvironmentTests`'.
@MainActor
final class PRHubOpenLinkUITests: PRHubUITestCase {
    func testAHandoffFromSettingsOpensTheRequestedPR() throws {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()
        app.go(to: .settings)
        try XCUIDevice.shared.system.open(handoff("https://github.com/acme/web/pull/412"))

        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["acme/web#412"].exists, "the requested PR's detail, not its list row")
        recordScreenshot("handoff-requested-pr")
    }

    private func handoff(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try XCTUnwrap(parts.url)
    }
}
