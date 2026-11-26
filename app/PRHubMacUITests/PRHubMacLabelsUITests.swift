import XCTest

/// A PR's labels on the Mac, over the sample PR acme/web#412: Labels in the header opens the repo's labels in the panel
/// over the page, and a click on one puts it on the PR, where its chip then shows. Pictures stay in the test's result
/// bundle.
@MainActor
final class PRHubMacLabelsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// What a row says of its label, wherever the Mac puts those words.
    private func says(_ element: XCUIElement, _ words: String) -> Bool {
        [element.label, element.title, element.value as? String ?? ""].contains(words)
    }

    /// The app's window alone, never the whole screen.
    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Not `async`: with `continueAfterFailure` off, a failed assertion in an async test never returned.
    func testALabelIsPutOnFromTheListAndShowsOnThePRsPage() {
        // No windows of an earlier run. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Show a retry button when checkout fails"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the sample PR's card")
        app.activate()
        card.click()

        let edit = element("pr-labels-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "Labels, in the PR's header")
        XCTAssertTrue(element("pr-label-chip-sample").exists, "the PR's own label, as a chip")
        edit.click()

        let bug = element("pr-label-bug")
        XCTAssertTrue(bug.waitForExistence(timeout: 5), "the repo's labels, in the panel")
        XCTAssertTrue(says(bug, "bug, off"), "label \(bug.label), title \(bug.title)")
        XCTAssertTrue(says(element("pr-label-sample"), "sample, on"), "the PR's own label is ticked")
        picture("mac-labels-list")

        bug.click()
        for _ in 0 ..< 50 where !says(bug, "bug, on") {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        XCTAssertTrue(says(bug, "bug, on"), "ticked at once: label \(bug.label), title \(bug.title)")

        element("pr-labels-close").click()
        XCTAssertTrue(element("pr-label-chip-bug").waitForExistence(timeout: 5), "its chip, on the PR's page")
        picture("mac-labels-added")
    }
}
