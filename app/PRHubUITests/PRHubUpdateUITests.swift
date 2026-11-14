import XCTest

/// Update available, from a config whose `app_latest` is newer than this build, the same, or skipped with Later
/// (`-PRHubNewerBuild`, PRHubScreenshots).
@MainActor
final class PRHubUpdateUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    private var prompt: XCUIElement {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Update available: PRHub'")).firstMatch
    }

    private func launch(newer: Int, forgetLater: Bool = false) {
        app.terminate()
        app.launchArguments = ["-PRHubPaired", "-PRHubNewerBuild", String(newer)]
            + (forgetLater ? ["-PRHubForgetLater"] : [])
        app.launch()
        XCTAssertTrue(app.tab(.prs).waitForExistence(timeout: 20), "the PRs tab")
    }

    func testANewerBuildIsOfferedUntilLater() {
        launch(newer: 1, forgetLater: true)
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "a newer build is offered")
        XCTAssertTrue(prompt.buttons["Update"].exists)
        attach(name: "update-available")
        prompt.buttons["Later"].tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2))

        launch(newer: 1)
        XCTAssertFalse(prompt.waitForExistence(timeout: 3), "Later skips that build")

        launch(newer: 2)
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "a build newer than the one skipped is offered")
        prompt.buttons["Later"].tap()
    }

    func testTheSameBuildOffersNothing() {
        launch(newer: 0, forgetLater: true)
        XCTAssertFalse(prompt.waitForExistence(timeout: 3))
    }

    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
