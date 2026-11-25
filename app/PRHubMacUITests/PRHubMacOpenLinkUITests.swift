import AppKit
import XCTest

/// A PR link from another app on the Mac (`prhub-pr://open`, as a link router such as Finicky sends for a GitHub PR
/// link): it opens in the PRs window that is already there. The Mac used to open one more PRs window for every link
/// (Jai's Mac, 2026-11-25: five links, five windows).
@MainActor
final class PRHubMacOpenLinkUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testALinkFromAnotherAppOpensInThePRsWindowThatIsOpen() async throws {
        // No windows of an earlier run. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let list = app.descendants(matching: .any)["pr-list-page"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the PRs window")
        XCTAssertEqual(app.windows.count, 1, "one PRs window before any link")

        try await open("https://github.com/acme/web/pull/412")
        XCTAssertTrue(app.buttons["pr-review-changes"].firstMatch.waitForExistence(timeout: 15), "the PR the link names")
        XCTAssertEqual(app.windows.count, 1, "the link opened in the window that was open")

        try await open("https://github.com/acme/web/pull/412/files")
        // The system has delivered the link once PRHub is in front again; a second window would be there by then.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(app.windows.count, 1, "a second link opens no second window")
    }

    /// Hands the PRHub under test the link, as the system does for another app: to this copy, whichever other copies
    /// the Mac knows.
    private func open(_ target: String) async throws {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        let link = try XCTUnwrap(parts.url)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.jaigovindani.prreview")
        let bundle = try XCTUnwrap(running.first?.bundleURL, "PRHub is running")
        try await NSWorkspace.shared.open([link], withApplicationAt: bundle, configuration: .init())
    }
}
