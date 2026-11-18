import XCTest

/// Shared by the manual checks against a deployed Worker.
@MainActor
class E2ETestCase: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
        try await super.tearDown()
    }

    func launch() {
        app.launchArguments = ["-PRHubSelfHosted", "YES"]
        app.launch()
    }

    func verifyPairing(_ target: E2ETarget) throws {
        try require(app.tab(.settings).waitForExistence(timeout: 60), "Pair the dedicated test install first.")
        app.go(to: .settings)
        let host = app.descendants(matching: .any)["prhub-worker-host"]
        try require(host.waitForExistence(timeout: 10), "Expected self-hosted Worker Settings, not samples or hosted sign-in.")
        let expectedHost = try XCTUnwrap(target.worker.host)
        try require(matchesValue(host.label, name: "Worker", value: expectedHost), "The paired Worker does not match the configured test origin.")
        let login = app.descendants(matching: .any).matching(NSPredicate(
            format: "label MATCHES %@", valuePattern(name: "GitHub login", value: target.login)
        )).firstMatch
        try require(login.waitForExistence(timeout: 10), "The paired GitHub login does not match the configured test account.")
    }

    func openPR(_ target: E2ETarget) async throws {
        app.open(target.handoff)
        try await waitUntil("The exact configured PR and its content must open.", timeout: .seconds(60)) {
            self.showsPR(target)
        }
    }

    func showsPR(_ target: E2ETarget) -> Bool {
        app.navigationBars[target.reference].exists
            && app.staticTexts[target.title].exists
            && app.buttons["pr-review-changes"].exists
    }

    func waitUntil(_ message: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw E2EFailure(message) }
    }

    private func matchesValue(_ label: String, name: String, value: String) -> Bool {
        label.range(of: valuePattern(name: name, value: value), options: .regularExpression) != nil
    }

    private func valuePattern(name: String, value: String) -> String {
        "^\(NSRegularExpression.escapedPattern(for: name))[\\s,:]+\(NSRegularExpression.escapedPattern(for: value))$"
    }
}
