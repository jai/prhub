import XCTest

/// Sign in with GitHub against the fake hosted Worker (`PRHubScreenshots`): sign-in to the list, the Anthropic key,
/// Delete Account, a refused sign-in, Sign in again, a setup link in a build without self-hosting, an empty list, and
/// where the GitHub App is installed.
@MainActor
final class PRHubHostedUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
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
        field.tap()
        field.typeText("key-0123456789abcdefghij")
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

    func testARefusedSignInSaysWhyUnderItsButton() {
        app.launchArguments = ["-PRHubFirstRun", "-PRHubSignInDenied"]
        app.launch()
        let signIn = app.buttons["onboardingSignIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        let status = app.descendants(matching: .any)["onboardingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("didn't authorize"), status.label)
    }

    func testSignedOutByGitHubSignsInAgain() {
        app.launchArguments = ["-PRHubHosted", "-PRHubSignedOut"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["signedOutReason"].waitForExistence(timeout: 10))
        app.buttons["onboardingSignIn"].tap()
        XCTAssertTrue(app.staticTexts["Show a retry button when checkout fails"].waitForExistence(timeout: 10))
    }

    func testASetupLinkSaysSelfHostingIsOff() {
        app.launchArguments = ["-PRHubFirstRun"]
        app.launch()
        XCTAssertTrue(app.buttons["onboardingSignIn"].waitForExistence(timeout: 10))
        app.open(URL(string: "prhub://setup?worker=https%3A%2F%2Fpr-review.example.workers.dev&code=7KQ2M9XA")!)
        let status = app.descendants(matching: .any)["onboardingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("self-hosted"), status.label)
    }

    func testSettingsListsEachAccountTheAppIsInstalledOn() {
        app.launchArguments = ["-PRHubHosted", "-PRHubSettings"]
        app.launch()
        let own = app.descendants(matching: .any)["github-installation-octocat"]
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        XCTAssertTrue(own.label.contains("All repositories"), own.label)
        let acme = app.descendants(matching: .any)["github-installation-acme"]
        XCTAssertTrue(acme.label.contains("2 repositories"), acme.label)
        let initech = app.descendants(matching: .any)["github-installation-initech"]
        XCTAssertTrue(app.scrollSettings(to: initech))
        XCTAssertTrue(initech.label.contains("Suspended"), initech.label)
        XCTAssertTrue(app.descendants(matching: .any)["github-access-add-account"].exists)
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

    func testAnEmptyListSaysTheAppIsOnNoAccount() {
        app.launchArguments = ["-PRHubHosted", "-PRHubHostedEmpty", "-PRHubInstallations", "none"]
        app.launch()
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        XCTAssertTrue(app.staticTexts["PRHub isn't installed yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].exists)
    }

    func testAnEmptyListPointsAtInstallingTheApp() {
        app.launchArguments = ["-PRHubHosted", "-PRHubHostedEmpty"]
        app.launch()
        // The offer of review alerts comes first: the fake Worker pushes.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["pr-empty-hint-link"].waitForExistence(timeout: 10))
    }
}
