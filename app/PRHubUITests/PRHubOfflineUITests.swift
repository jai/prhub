import XCTest

/// With no network the PRs still show, under one quiet line saying they are the saved ones (issue #52).
@MainActor
final class PRHubOfflineUITests: XCTestCase {
    private let app = XCUIApplication()
    private let banner = "prkit-offline-banner"

    override func setUp() {
        continueAfterFailure = false
    }

    func testOfflineShowsTheSavedPRsUnderTheBannerOnEveryTab() {
        app.launchArguments = ["-PRHubPaired", "-PRHubOffline"]
        app.launch()

        let bannerLine = app.descendants(matching: .any)[banner]
        XCTAssertTrue(bannerLine.waitForExistence(timeout: 10), "the offline banner")
        XCTAssertEqual(bannerLine.label, "Offline — showing saved information")
        XCTAssertTrue(savedPR.waitForExistence(timeout: 5), "the saved PRs")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Not up to date'")).firstMatch
            .exists, "no second line about the same failure")
        keep("offline-prs")

        app.go(to: .settings)
        XCTAssertTrue(bannerLine.waitForExistence(timeout: 5), "the banner over Settings too")
    }

    func testOnlineShowsNoBanner() {
        app.launchArguments = ["-PRHubPaired"]
        app.launch()

        XCTAssertTrue(savedPR.waitForExistence(timeout: 10), "the PRs")
        XCTAssertFalse(app.descendants(matching: .any)[banner].exists, "no offline banner while online")
    }

    /// The real path: the PRs load from a Worker (the app's stand-in) into the mirror, the app is quit, and it opens
    /// again with no network on what it saved: the list, and a PR's page.
    func testWhatLoadedOnlineOpensAgainOfflineAfterARelaunch() {
        app.launchArguments = ["-PRHubStubWorker", "-PRHubStubWorkerFresh"]
        app.launch()
        XCTAssertTrue(savedPR.waitForExistence(timeout: 30), "the PRs, read from the Worker")
        XCTAssertFalse(app.descendants(matching: .any)[banner].exists, "online")
        app.terminate()

        app.launchArguments = ["-PRHubStubWorker", "-PRHubOffline"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[banner].waitForExistence(timeout: 10), "the offline banner")
        XCTAssertTrue(savedPR.waitForExistence(timeout: 5), "the saved PRs, with no network")
        keep("offline-relaunch-prs")

        let title = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 10), "the saved PR's page")
        XCTAssertFalse(app.staticTexts["Couldn't read this PR"].exists)
        keep("offline-relaunch-pr")
    }

    /// A PR never read on this device, opened by a link with no network: it says so, not an error.
    func testAnUnsavedPROpenedOfflineSaysItIsNotSaved() throws {
        app.launchArguments = ["-PRHubStubWorker", "-PRHubStubWorkerFresh", "-PRHubOffline"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[banner].waitForExistence(timeout: 10))
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: "https://github.com/acme/web/pull/412")]
        try XCUIDevice.shared.system.open(XCTUnwrap(parts.url))

        let notSaved = app.descendants(matching: .any)["pr-not-saved-offline"]
        XCTAssertTrue(notSaved.waitForExistence(timeout: 10), "the PR's offline state")
        XCTAssertFalse(app.staticTexts["Couldn't read this PR"].exists)
        keep("offline-unsaved-pr")
    }

    /// A sample PR's row, by its Review button.
    private var savedPR: XCUIElement {
        app.buttons["pr-row-review-acme/web#412"]
    }

    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
