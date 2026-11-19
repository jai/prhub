import XCTest

/// With no network the PRs still show, under one quiet line saying they are the saved ones (issue #52).
@MainActor
final class PRHubOfflineUITests: PRHubUITestCase {
    private let banner = "prkit-offline-banner"

    /// The real path: the PRs load from a Worker (the app's stand-in) into the mirror, the app is quit, and it opens
    /// again with no network on what it saved: the list, and a PR's page.
    func testWhatLoadedOnlineOpensAgainOfflineAfterARelaunch() throws {
        app.launchArguments = ["-PRHubStubWorker"]
        app.launch()
        XCTAssertTrue(savedPR.waitForExistence(timeout: 30), "the PRs, read from the Worker")
        XCTAssertFalse(app.descendants(matching: .any)[banner].exists, "online")

        relaunch(["-PRHubStubWorker", "-PRHubOffline"])
        XCTAssertTrue(app.descendants(matching: .any)[banner].waitForExistence(timeout: 10), "the offline banner")
        XCTAssertTrue(savedPR.waitForExistence(timeout: 5), "the saved PRs, with no network")
        try recordScreenshot("offline-relaunch-prs")

        let title = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10), "the saved PR's page")
        XCTAssertFalse(app.staticTexts["Couldn't read this PR"].exists)
        try recordScreenshot("offline-relaunch-pr")
    }

    /// A sample PR's row, by its Review button.
    private var savedPR: XCUIElement {
        app.buttons["pr-row-review-acme/web#412"]
    }
}
