import XCTest

/// Update available, from a config whose `app_latest` is newer than this build, the same, or skipped with Later
/// (`-PRHubNewerBuild`, PRHubScreenshots).
@MainActor
final class PRHubUpdateUITests: PRHubUITestCase {
    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
    }

    private var prompt: XCUIElement {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Update available: PRHub'")).firstMatch
    }

    /// The first launch in a test starts afresh; later ones keep what Later skipped.
    private func launch(newer: Int, keepingState: Bool = false) {
        let arguments = ["-PRHubPaired", "-PRHubNewerBuild", String(newer)]
        if keepingState {
            relaunch(arguments)
        } else {
            app.launchArguments = arguments
            app.launch()
        }
        XCTAssertTrue(app.tab(.prs).waitForExistence(timeout: 20), "the PRs tab")
    }

    func testANewerBuildIsOfferedUntilLater() throws {
        launch(newer: 1)
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "a newer build is offered")
        XCTAssertTrue(prompt.buttons["Update"].exists)
        try recordScreenshot("update-available")
        prompt.buttons["Later"].tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2))

        launch(newer: 1, keepingState: true)
        XCTAssertFalse(prompt.waitForExistence(timeout: 3), "Later skips that build")

        launch(newer: 2, keepingState: true)
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "a build newer than the one skipped is offered")
        prompt.buttons["Later"].tap()
    }

    func testTheSameBuildOffersNothing() {
        launch(newer: 0)
        XCTAssertFalse(prompt.waitForExistence(timeout: 3))
    }
}
