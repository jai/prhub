import XCTest

/// A PR's labels put on and taken off, over the sample PR acme/web#412, which comes with the label "sample" on a repo
/// of eight made-up labels (`PRSampleSet.sampleLabels`). Labels, first in the header's row of chips, opens the repo's
/// labels in a panel over the page; a tap on a row puts its label on the PR or takes it off, and the page's chips
/// follow. What is sent and what a refusal does is `PRLabelsTests`'. One launch a test. Pictures stay in the test's
/// result bundle.
@MainActor
final class PRKitLabelsUITests: PRHubUITestCase {
    private let checkout = "Show a retry button when checkout fails"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    func testTheListShowsTheReposLabelsWithThePRsTicked() {
        openTheList()
        XCTAssertTrue(element("pr-labels-list").exists, "the panel")
        XCTAssertEqual(row("sample").label, "sample, on", "the label the PR came with is ticked")
        XCTAssertEqual(row("bug").label, "bug, off")
        XCTAssertEqual(row("needs-design").label, "needs-design, off")
        XCTAssertTrue(element("pr-labels-filter").exists, "the field that narrows the list")
        XCTAssertFalse(element("pr-labels-read-only").exists, "these can be changed")
        recordScreenshot("labels-list")
    }

    func testALabelIsPutOnAndItsChipShowsOnThePage() {
        openTheList()
        let bug = row("bug")
        bug.tap()
        XCTAssertTrue(waitFor { bug.label == "bug, on" }, "ticked at once: \(bug.label)")
        XCTAssertEqual(row("sample").label, "sample, on", "the others stay as they were")
        closeTheList()
        XCTAssertTrue(chip("bug").waitForExistence(timeout: 5), "its chip, on the PR's page")
        XCTAssertTrue(chip("sample").exists, "beside the one the PR came with")
        XCTAssertEqual(app.buttons["pr-labels-edit"].label, "Labels", "the way in reads the same")
        recordScreenshot("labels-added")
    }

    func testALabelIsTakenOffAndItsChipGoes() {
        openTheList()
        let sample = row("sample")
        sample.tap()
        XCTAssertTrue(waitFor { sample.label == "sample, off" }, "its tick goes at once: \(sample.label)")
        closeTheList()
        XCTAssertTrue(waitFor { !self.chip("sample").exists }, "its chip leaves the page")
        XCTAssertTrue(app.buttons["pr-labels-edit"].exists, "the way in stays on a PR with no labels")
        recordScreenshot("labels-removed")
    }

    func testLabelsThatCanNotBeChangedAreReadAndSaySo() {
        openTheList(["-PRHubLabelsReadOnly"])
        let note = element("pr-labels-read-only")
        XCTAssertTrue(note.exists, "why a tap does nothing")
        XCTAssertEqual(note.label, "You can't change labels on this repo.")
        XCTAssertEqual(row("bug").label, "bug, off")
        row("bug").tap()
        XCTAssertFalse(waitFor(timeout: 1) { self.row("bug").label == "bug, on" }, "a tap changes nothing")
        recordScreenshot("labels-read-only")
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

    /// The sample PR's page, then Labels: the panel with the repo's labels read.
    private func openTheList(_ arguments: [String] = []) {
        app.launch(["-PRHubPaired", "-prhubAlertsDeclined", "YES"] + arguments, appearance: .light)
        app.openPR(checkout)
        let edit = app.buttons["pr-labels-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Labels, in the PR's header")
        XCTAssertTrue(chip("sample").exists, "the PR's own label, as a chip")
        edit.tap()
        XCTAssertTrue(row("bug").waitForExistence(timeout: 5), "the repo's labels")
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
