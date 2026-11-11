import XCTest

/// Folding a file from its pinned header, read from inside the file, keeps the header where it is on screen: it never
/// scrolls off, and the next file comes up under it. On `-PRHubLongDiff`'s PR of three long files. The hitch test
/// measures the fold with `XCTHitchMetric` on a device; the Simulator records no hitches, so there it is skipped.
@MainActor
final class PRHubFoldUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testFoldingFromAPinnedHeaderKeepsItInPlace() {
        let header = openSecondFilePinned()
        let before = header.frame.minY
        header.tap()
        let tops = sampleTops(of: header, for: 1)
        XCTAssertEqual(header.value as? String, "collapsed")
        XCTAssertTrue(
            tops.allSatisfy { abs($0 - before) <= 2 }, "the header left its place while folding: \(before) → \(tops)"
        )
        XCTAssertTrue(header.isHittable, "the folded header is still on screen")
        XCTAssertTrue(app.buttons["file-header-2"].isHittable, "the next file comes up under it")

        header.tap()
        XCTAssertEqual(header.value as? String, "open")
        XCTAssertTrue(header.isHittable, "opened again, the header is still on screen")
    }

    func testFoldingHitches() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
            "XCTHitchMetric measures nothing on the Simulator: run on a device"
        )
        let header = openSecondFilePinned()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            header.tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
            header.tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
        }
    }

    /// The three-file PR's diff, scrolled into its second file until that file's header stays put: pinned.
    private func openSecondFilePinned() -> XCUIElement {
        app.launch(["-PRHubPaired", "-PRHubLongDiff"], appearance: .light)
        let row = app.staticTexts["Give every team access to staging"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let diff = app.buttons["pr-files-changed"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-header-0"].waitForExistence(timeout: 5))
        let header = app.buttons["file-header-1"]
        let table = app.tables.firstMatch
        var last: CGFloat?
        for _ in 0 ..< 20 {
            table.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.6))
            guard header.exists, header.isHittable else {
                last = nil
                continue
            }
            let top = header.frame.minY
            if let last, abs(top - last) <= 1, !app.buttons["file-header-0"].isHittable {
                return header
            }
            last = top
        }
        XCTFail("the second file's header never pinned")
        return header
    }

    /// Where the header's top is, again and again for `seconds`: off screen counts as far away.
    private func sampleTops(of header: XCUIElement, for seconds: TimeInterval) -> [CGFloat] {
        var tops: [CGFloat] = []
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            tops.append(header.exists && header.isHittable ? header.frame.minY : -10_000)
        }
        return tops
    }
}
