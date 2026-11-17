import XCTest

/// The end-to-end check of a tapped alert against a real Worker: pair with it, kill the app, wait for an alert sent to
/// the Simulator (`xcrun simctl push`), tap it and time the tap to the PR's content. Skipped unless the runner is given
/// `TEST_RUNNER_PRHUB_E2E_SETUP` (a `prhub://setup` link) for `testPairing`, or `TEST_RUNNER_PRHUB_E2E` for
/// `testTapToContent`, which prints `PRHUB-E2E-READY` once the app is killed and `PRHUB-E2E-TAP-TO-CONTENT-MS=`. CI
/// runs neither.
@MainActor
final class PRHubPushOpenE2ETests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testPairing() throws {
        let setup = ProcessInfo.processInfo.environment["PRHUB_E2E_SETUP"]
        try XCTSkipUnless(setup != nil, "an end-to-end run only")
        let cancel = springboard.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        }
        app.launchArguments = ["-PRHubSelfHosted", "YES"]
        app.launch()
        // `paired`: the app is paired already, and only alerts are left to turn on.
        if let link = setup.flatMap(URL.init(string:)), setup != "paired" {
            app.open(link)
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 3) {
                open.tap()
            }
        }
        let turnOn = app.buttons["Turn on"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 60), "the offer to turn on alerts")
        turnOn.tap()
        let allow = springboard.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the system's question")
        allow.tap()
        XCTAssertTrue(app.tab(.prs).waitForExistence(timeout: 10))
    }

    func testTapToContent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRHUB_E2E"] != nil, "an end-to-end run only")
        app.terminate()
        XCUIDevice.shared.press(.home)
        print("PRHUB-E2E-READY")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Review requested'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 180), "the alert's banner")
        let tapped = Date.now
        banner.tap()
        let content = app.buttons["pr-review-changes"]
        var shown: Date?
        while Date.now.timeIntervalSince(tapped) < 30 {
            if content.exists {
                shown = .now
                break
            }
        }
        let milliseconds = shown.map { Int($0.timeIntervalSince(tapped) * 1000) }
        print("PRHUB-E2E-TAP-TO-CONTENT-MS=\(milliseconds.map(String.init) ?? "none")")
        XCTAssertNotNil(shown, "the PR's content within 30 s of the tap")
    }
}
