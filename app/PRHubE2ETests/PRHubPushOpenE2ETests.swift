import XCTest

/// Self-hosted pairing and locally injected notification navigation. Injection does not prove APNs delivery.
@MainActor
final class PRHubPushOpenE2ETests: E2ETestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testFreshPairingConnectsTheExpectedWorkerAndOffersAlerts() throws {
        let target = try E2ETarget.load()
        let setup = try target.setupLink()
        launch()
        try require(app.buttons["onboardingOwnWorker"].waitForExistence(timeout: 15),
                    "Pairing requires an unpaired dedicated install; an existing pairing is not accepted.")
        app.open(setup)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) {
            open.tap()
        }
        let turnOn = app.buttons["Turn on"]
        try require(turnOn.waitForExistence(timeout: 60), "The dedicated Worker must offer review alerts after pairing.")
        turnOn.tap()
        let allow = springboard.alerts.buttons["Allow"]
        try require(allow.waitForExistence(timeout: 10), "Use a dedicated install with notification permission not yet requested.")
        allow.tap()
        try verifyPairing(target)
    }

    /// The runner injects one payload after READY, containing the new notification UUID and exact PR reference.
    func testInjectedNotificationOpensTheExpectedPR() async throws {
        let target = try E2ETarget.load()
        let marker = UUID().uuidString
        launch()
        try verifyPairing(target)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Review requested: \(target.reference)", marker
        )).firstMatch
        app.terminate()
        XCUIDevice.shared.press(.home)
        print("PRHUB-INJECTED-NOTIFICATION-READY id=\(marker) pr=\(target.reference)")
        try require(banner.waitForExistence(timeout: 180), "The runner must inject the matching notification after READY.")
        let tapped = ContinuousClock.now
        banner.tap()
        try await waitUntil("The notification must open the exact PR and loaded content within 30 seconds.", timeout: .seconds(30)) {
            self.showsPR(target)
        }
        let elapsed = tapped.duration(to: ContinuousClock.now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        print("PRHUB-INJECTED-TAP-TO-CONTENT-MS=\(Int(milliseconds)) id=\(marker) pr=\(target.reference)")
    }
}
