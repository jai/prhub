import XCTest

/// A PR's labels put on and taken off on a real screen, over the sample PR acme/web#412, which comes with the label
/// "sample" on a repo of eight made-up labels (`PRSampleSet.sampleLabels`). Labels, first in the header's row of chips,
/// opens the repo's labels in a panel over the page; a tap on a row puts its label on the PR or takes it off, and the
/// page's chips follow. One launch.
///
/// What needs no running app is proven below this: the list drawn with the repo's labels and the PR's ticked, and
/// the line that says so where they can't be changed, in light and dark, with their pictures
/// (`PRLabelsPanelRenderingTests`); what is ticked, what is sent and what a refusal does (`PRLabelsTests`).
@MainActor
final class PRKitLabelsUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    func testALabelIsPutOnAndTakenOffAndItsChipFollowsOnThePage() {
        app.launch(["-PRHubPaired", "-prhubAlertsDeclined", "YES"], appearance: .light)
        app.openPR(checkout)
        let edit = app.buttons["pr-labels-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Labels, in the PR's header")
        XCTAssertTrue(chip("sample").exists, "the PR's own label, as a chip")
        XCTAssertFalse(chip("bug").exists)

        // On: ticked at once in the panel, and a chip on the page once it is closed.
        openTheList()
        let bug = row("bug")
        XCTAssertEqual(bug.label, "bug, off")
        XCTAssertEqual(row("sample").label, "sample, on", "the label the PR came with is ticked")
        bug.tap()
        XCTAssertTrue(waitFor { bug.label == "bug, on" }, "ticked at once: \(bug.label)")
        XCTAssertEqual(row("sample").label, "sample, on", "the others stay as they were")
        closeTheList()
        XCTAssertTrue(chip("bug").waitForExistence(timeout: 5), "its chip, on the PR's page")
        XCTAssertTrue(chip("sample").exists, "beside the one the PR came with")
        XCTAssertEqual(edit.label, "Labels", "the way in reads the same")

        // Off: its tick goes at once, and its chip leaves the page.
        openTheList()
        XCTAssertEqual(bug.label, "bug, on", "as it was left")
        bug.tap()
        XCTAssertTrue(waitFor { bug.label == "bug, off" }, "its tick goes at once: \(bug.label)")
        closeTheList()
        XCTAssertTrue(waitFor { !self.chip("bug").exists }, "its chip leaves the page")
        XCTAssertTrue(chip("sample").exists, "the PR's own label stays")
    }

    // MARK: - Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// A label's row in the panel: a button where labels can be changed, else words.
    private func row(_ name: String) -> XCUIElement {
        element("pr-label-\(name)")
    }

    /// A label's chip in the PR's header.
    private func chip(_ name: String) -> XCUIElement {
        app.staticTexts["pr-label-chip-\(name)"].firstMatch
    }

    /// Labels, on the PR's page: the panel with the repo's labels read.
    private func openTheList() {
        let edit = app.buttons["pr-labels-edit"]
        XCTAssertTrue(waitFor { edit.exists && edit.isHittable }, "Labels, in the PR's header")
        app.waitForStill(edit)
        edit.tap()
        XCTAssertTrue(row("bug").waitForExistence(timeout: 5), "the repo's labels")
        XCTAssertTrue(waitFor { self.row("bug").isHittable }, "the panel is over the page")
        app.waitForStill(row("bug"))
    }

    /// Close, in the panel's heading. The panel has gone once its rows take no tap: one sliding out can stay in what
    /// a test reads for a moment after it has left the screen. A failure says where Close was and what was over it.
    private func closeTheList() {
        let close = app.buttons["pr-labels-close"].firstMatch
        let bar = app.navigationBars.firstMatch
        let place = "Close at \(close.frame), hittable \(close.isHittable); the nav bar at \(bar.frame)"
        XCTAssertTrue(close.isHittable, place)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44, "a finger's width. \(place)")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44, "a finger's height. \(place)")
        close.tap()
        let bug = row("bug")
        XCTAssertTrue(
            waitFor { !bug.exists || !bug.isHittable },
            "the panel has gone. \(place); the app is \(app.state == .runningForeground ? "in front" : "not in front")"
        )
    }
}
