import XCTest

/// Sign in with GitHub against the fake hosted Worker (`PRHubFixtureLaunch`): sign-in to the list, the Anthropic key and
/// Delete Account, and a new install read again on the way back from GitHub. The connection's logic is
/// `HostedConnectionTests`'.
@MainActor
final class PRHubHostedUITests: PRHubUITestCase {
    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.appearance = .light
    }

    func testSignInSetAKeyThenDeleteTheAccount() {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()
        XCTAssertFalse(app.buttons["onboardingOwnWorker"].exists, "self-hosted Workers are off in this build")
        let signIn = app.buttons["onboardingSignIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        XCTAssertTrue(app.staticTexts["Show a retry button when checkout fails"].waitForExistence(timeout: 10))

        app.go(to: .settings)
        let login = app.descendants(matching: .any)["prhub-account-login"]
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["github-access-add-account"].exists)

        let field = app.secureTextFields["prhub-anthropic-key-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type("key-0123456789abcdefghij", into: field)
        app.buttons["prhub-anthropic-key-save"].tap()
        let keySet = app.descendants(matching: .any)["prhub-anthropic-key-set"]
        XCTAssertTrue(keySet.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["key-0123456789abcdefghij"].exists, "the key is never shown back")
        app.buttons["prhub-anthropic-key-remove"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        let delete = app.buttons["prhub-delete-account"]
        XCTAssertTrue(app.scrollSettings(to: delete))
        delete.tap()
        let confirm = app.buttons["prhub-delete-account-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "back on onboarding, with nothing kept")
    }

    func testANewInstallShowsWhenTheAppComesBackFromGitHub() {
        app.launchArguments = ["-PRHubHosted", "-PRHubSettings", "-PRHubInstallations", "onReturn"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["github-installation-octocat"].waitForExistence(timeout: 10))
        let acme = app.descendants(matching: .any)["github-installation-acme"]
        XCTAssertFalse(acme.exists)
        let add = app.descendants(matching: .any)["github-access-add-account"]
        XCTAssertTrue(app.scrollSettings(to: add))
        add.tap()
        // GitHub's install page opens in Safari, which can take half a minute to start on a CI Simulator; Home leaves
        // the app at once on an iPhone and an iPad alike. The person installs on acme there and comes back.
        XCUIDevice.shared.press(.home)
        let left = expectation(for: NSPredicate { _, _ in self.app.state != .runningForeground }, evaluatedWith: nil)
        wait(for: [left], timeout: 30)
        app.activate()
        XCTAssertTrue(acme.waitForExistence(timeout: 10), "the config is read again on the way back")
    }

    // A picture for the test's result.
}
