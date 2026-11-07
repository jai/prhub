import XCTest

/// Pictures of every screen in light, dark and the largest accessibility text, over the sample PRs: onboarding, the
/// list, a PR, its diff on a key line, and Settings. Each is an attachment, and a PNG in `SCREENSHOTS_DIR` when the
/// run sets it (`TEST_RUNNER_SCREENSHOTS_DIR` on xcodebuild's command line).
@MainActor
final class PRHubScreenshotTests: XCTestCase {
    private enum Look: String, CaseIterable {
        case light, dark, largeText = "large-text"
    }

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryScreenInEveryLook() throws {
        for look in Look.allCases {
            try pictures(look)
        }
    }

    private func launch(_ look: Look, _ arguments: [String]) {
        XCUIDevice.shared.appearance = look == .dark ? .dark : .light
        app.terminate()
        app.launchArguments = arguments + (look == .largeText
            ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : [])
        app.launch()
    }

    private func pictures(_ look: Look) throws {
        launch(look, ["-PRHubFirstRun"])
        XCTAssertTrue(app.buttons["onboardingScan"].waitForExistence(timeout: 10))
        try picture("1-onboarding", look)

        launch(look, ["-PRHubPaired"])
        let checkout = app.staticTexts["Show a retry button when checkout fails"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        try picture("2-list", look)
        checkout.tap()
        XCTAssertTrue(app.buttons["Diff"].waitForExistence(timeout: 5))
        try picture("3-pr", look)
        app.buttons["Diff"].tap()
        XCTAssertTrue(app.buttons["key-line-next"].waitForExistence(timeout: 5))
        app.buttons["key-line-next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))
        try picture("4-diff-key-line", look)

        launch(look, ["-PRHubPaired", "-PRHubSettings"])
        XCTAssertTrue(app.staticTexts["prhub-worker-host"].waitForExistence(timeout: 10)
            || app.descendants(matching: .any)["prhub-worker-host"].waitForExistence(timeout: 5))
        try picture("5-settings", look)
    }

    private func picture(_ step: String, _ look: Look) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(step)-\(look.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(step)-\(look.rawValue).png"))
    }
}
