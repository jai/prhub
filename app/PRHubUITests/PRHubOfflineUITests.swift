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
