import XCTest

/// The code scrolls sideways and nothing else does: at the left edge a swipe right moves nothing, and the file header
/// and a key line's note stay whole and in view wherever the code is; in the largest text the note stays clear of its
/// stepper. On the sample PRs, at the default text size and the largest.
@MainActor
final class PRHubDiffSidewaysUITests: PRHubUITestCase {
    /// Review alerts already declined: the offer came up over the PR on an iPad and took the tap meant for Review
    /// changes (CI's recording, 2026-11-14).
    private static let noAlertsOffer = ["-prhubAlertsDeclined", "YES"]

    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"

    // One launch a test: each text size is its own test, so a slow or failed size fails alone and the next starts
    // from a fresh app.

    /// Where everything is once the finger lifts. XCUITest can't look while the finger is down, where a bounce shows:
    /// that is `DiffTableEdgeTests`' and the recording's.
    func testASwipeRightAtTheLeftEdgeMovesNothing() throws {
        try swipeRightAtTheLeftEdge("default", textSize: nil)
    }

    func testASwipeRightAtTheLeftEdgeMovesNothingInTheLargestText() throws {
        try swipeRightAtTheLeftEdge("largest", textSize: Self.largest)
    }

    /// A horizontal drag moves an overflowing code canvas, or leaves a fitting canvas still; the header and note stay.
    func testTheHeaderAndTheNoteStayDuringAHorizontalDrag() throws {
        try headerAndNoteStay("default", textSize: nil)
    }

    func testTheHeaderAndTheNoteStayDuringAHorizontalDragInTheLargestText() throws {
        try headerAndNoteStay("largest", textSize: Self.largest)
    }

    /// In the largest text the note ran down to the stepper (Xcode Cloud's picture, 2026-11-14): 2 pt apart.
    func testTheNoteIsClearOfTheStepperInTheLargestText() throws {
        try openKeyLineNote(textSize: Self.largest)
        let note = app.descendants(matching: .any)["key-line-note"]
        let stepper = app.buttons["key-line-next"]
        XCTAssertLessThanOrEqual(note.frame.maxY + 8, stepper.frame.minY, "the note is clear of the stepper")
    }

    private func swipeRightAtTheLeftEdge(_ name: String, textSize: String?) throws {
        try openKeyLineNote(textSize: textSize)
        let before = Positions(app)
        recordScreenshot("diff-sideways-\(name)-1-open")

        drag(from: 0.3, by: 200, holding: 0.5)
        recordScreenshot("diff-sideways-\(name)-2-swiped-right")
        let after = Positions(app)
        XCTAssertEqual(after.line, before.line, "\(name): the code's first line stays at the left edge")
        XCTAssertEqual(after.header, before.header, "\(name): the header's path stays where it was")
        XCTAssertEqual(after.viewed, before.viewed, "\(name): the header's viewed mark stays where it was")
        XCTAssertTrue(after.isNoteInside, "\(name): the note is inside the screen, \(after.note)")
    }

    private func headerAndNoteStay(_ name: String, textSize: String?) throws {
        try openKeyLineNote(textSize: textSize)
        let before = drag(from: 0.6, by: -150, holding: 0.3, bringingUpCode: true)
        recordScreenshot("diff-sideways-\(name)-3-scrolled-left")
        let after = Positions(app)
        // DiffTableContainer gives each code cell the full canvas width. DiffFileHeader pins the viewed button's
        // trailing edge to the viewport. Classify the geometry before the gesture, never from whether it moved.
        XCTAssertGreaterThan(before.line.width, 0, "the code canvas is present")
        XCTAssertGreaterThan(before.viewed.width, 0, "the viewport's trailing control is present")
        if before.line.maxX > before.viewed.maxX + 1 {
            XCTAssertLessThan(after.line.minX, before.line.minX, "\(name): overflowing code must scroll sideways")
        } else {
            XCTAssertEqual(after.line, before.line, "\(name): code that fits must stay in place")
        }
        XCTAssertEqual(after.header, before.header, "\(name): the header's path did not move")
        XCTAssertEqual(after.viewed, before.viewed, "\(name): the header's viewed mark did not move")
        XCTAssertTrue(after.isNoteInside, "\(name): the note is inside the screen, \(after.note)")
    }

    /// A finger on the first code line under the pinned header, `start` of the way across the diff (from its header's
    /// path to its viewed mark: an iPad's list may be beside it), moved `distance` sideways.
    @discardableResult
    private func drag(
        from start: CGFloat, by distance: CGFloat, holding: TimeInterval, bringingUpCode: Bool = false
    ) -> Positions {
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        var positions = Positions(app)
        // The topmost line under the header, well above the screen's bottom edge: a sideways drag there switches apps.
        var below: [CGRect] {
            lines.allElementsBoundByIndex.map(\.frame)
                .filter { $0.minY > positions.header.maxY && $0.maxY < positions.screen.maxY * 0.75 }
        }
        for _ in 0 ..< 3 where bringingUpCode && below.isEmpty {
            app.tables.firstMatch.swipeUp(velocity: .slow)
            positions = Positions(app)
        }
        let line = below.min { $0.minY < $1.minY } ?? lines.firstMatch.frame
        let left = positions.header.minX
        let finger = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left + (positions.viewed.maxX - left) * start, dy: line.midY))
        finger.press(
            forDuration: 0.05, thenDragTo: finger.withOffset(CGVector(dx: distance, dy: 0)), withVelocity: .slow,
            thenHoldForDuration: holding
        )
        // Until the code stops: a snapshot taken mid-scroll can catch the header a frame behind it.
        let first = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'")).firstMatch
        app.waitForStill(first)
        return positions
    }

    /// The checkout sample's Files changed, its first key line's note open under its line.
    private func openKeyLineNote(textSize: String?) throws {
        app.launch(
            ["-PRHubPaired"] + Self.noAlertsOffer
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: .light
        )
        app.openPR("Show a retry button when checkout fails")
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(app.reveal(review), "Review changes, under the PR's summary")
        review.tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5))
        app.closePanelOverDiff()
        let next = app.buttons["key-line-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        let note = app.descendants(matching: .any)["key-line-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        app.waitForStill(note)
    }
}

/// Where the reader sees the diff's parts: the first code line on screen, the pinned file header's path and its viewed
/// mark at the bar's two ends, and the key line's note.
@MainActor
private struct Positions {
    let line: CGRect
    let header: CGRect
    let viewed: CGRect
    let note: CGRect
    let screen: CGRect

    init(_ app: XCUIApplication) {
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        line = lines.firstMatch.frame
        let headers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'file-header-'"))
        let header = headers.allElementsBoundByIndex.first { $0.isHittable } ?? headers.firstMatch
        self.header = header.frame
        let section = header.identifier.replacingOccurrences(of: "file-header-", with: "")
        viewed = app.buttons["file-viewed-\(section)"].frame
        note = app.descendants(matching: .any)["key-line-note"].frame
        screen = app.windows.firstMatch.frame
    }

    var isNoteInside: Bool {
        !note.isEmpty && note.minX >= screen.minX && note.maxX <= screen.maxX
    }
}
