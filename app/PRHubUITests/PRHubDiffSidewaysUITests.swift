import XCTest

/// The code scrolls sideways and nothing else does: at the left edge a swipe right moves nothing, and the file header
/// and a key line's note stay whole and in view wherever the code is. On the sample PRs, at the default text size and
/// the largest. Pictures go to `SCREENSHOTS_DIR` when set.
@MainActor
final class PRHubDiffSidewaysUITests: XCTestCase {
    private static let textSizes = [
        ("default", nil), ("largest", "UICTContentSizeCategoryAccessibilityXXXL"),
    ]

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    /// Where everything is once the finger lifts. XCUITest can't look while the finger is down, where a bounce shows:
    /// that is `DiffTableEdgeTests`' and the recording's.
    func testASwipeRightAtTheLeftEdgeMovesNothing() throws {
        for (name, textSize) in Self.textSizes {
            try openKeyLineNote(textSize: textSize)
            let before = Positions(app)
            try picture("diff-sideways-\(name)-1-open")

            drag(from: 0.3, by: 200, holding: 0.5)
            let after = Positions(app)
            XCTAssertEqual(after.line, before.line, "\(name): the code's first line stays at the left edge")
            XCTAssertEqual(after.header, before.header, "\(name): the header's path stays where it was")
            XCTAssertEqual(after.viewed, before.viewed, "\(name): the header's viewed mark stays where it was")
            XCTAssertTrue(after.isNoteInside, "\(name): the note is inside the screen, \(after.note)")
            try picture("diff-sideways-\(name)-2-swiped-right")
        }
    }

    /// Read halfway along a long line: the code has moved, the header and the note have not.
    func testTheHeaderAndTheNoteStayWhileTheCodeScrolls() throws {
        for (name, textSize) in Self.textSizes {
            try openKeyLineNote(textSize: textSize)
            let before = Positions(app)
            drag(from: 0.6, by: -150, holding: 0.3)
            let after = Positions(app)
            XCTAssertLessThan(after.line.minX, before.line.minX, "\(name): the code scrolled sideways")
            XCTAssertEqual(after.header, before.header, "\(name): the header's path did not move")
            XCTAssertEqual(after.viewed, before.viewed, "\(name): the header's viewed mark did not move")
            XCTAssertTrue(after.isNoteInside, "\(name): the note is inside the screen, \(after.note)")
            try picture("diff-sideways-\(name)-3-scrolled-left")
        }
    }

    /// A long path at Jai's text size and the largest: pictures of how much of it the header shows. Whether the whole
    /// file name fits is `DiffFileHeaderTests`'s: the label's text is the whole path either way.
    func testALongPathAtBigTextSizes() throws {
        for (name, textSize) in [("xxxl", "UICTContentSizeCategoryXXXL")] + Self.textSizes {
            app.launch(
                ["-PRHubPaired", "-PRHubLongDiff"] + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
                appearance: .light
            )
            openPR("Give the deploy team access to staging")
            let diff = app.buttons["pr-files-changed"]
            XCTAssertTrue(diff.waitForExistence(timeout: 5))
            diff.tap()
            XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 5))
            try picture("diff-sideways-long-path-\(name)")
        }
    }

    /// A finger on the first code line under the pinned header, `start` of the way across the screen, moved `distance`
    /// sideways.
    private func drag(from start: CGFloat, by distance: CGFloat, holding: TimeInterval) {
        let below = Positions(app).header.maxY
        let lines = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
        let line = (lines.allElementsBoundByIndex.first { $0.frame.minY > below } ?? lines.firstMatch).frame
        let screen = app.windows.firstMatch.frame
        let finger = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.width * start, dy: line.midY))
        finger.press(
            forDuration: 0.05, thenDragTo: finger.withOffset(CGVector(dx: distance, dy: 0)), withVelocity: .slow,
            thenHoldForDuration: holding
        )
    }

    /// A sample PR's row on For review, scrolled to: at the largest text size a row is taller than half the screen.
    private func openPR(_ title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(app.tab(.settings).waitForExistence(timeout: 10))
        for _ in 0..<15 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.isHittable, title)
        row.tap()
    }

    /// The checkout sample's Files changed, its first key line's note open under its line.
    private func openKeyLineNote(textSize: String?) throws {
        app.launch(
            ["-PRHubPaired"] + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: .light
        )
        openPR("Show a retry button when checkout fails")
        let review = app.buttons["pr-review-changes"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.buttons["key-lines-context-100"].waitForExistence(timeout: 5))
        app.closePanelOverDiff()
        let next = app.buttons["key-line-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date.now.addingTimeInterval(1))
    }

    private func picture(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
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
        note.minX >= screen.minX && note.maxX <= screen.maxX
    }
}
