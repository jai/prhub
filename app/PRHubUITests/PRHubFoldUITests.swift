import XCTest

/// Folding a file from its pinned header, read from inside the file, keeps the header where it is on screen: it never
/// scrolls off, and the next file comes up under it. On `-PRHubLongDiff`'s PR of three long files.
/// Device hitch measurements live in the separate PRHubPerformanceTests target.
@MainActor
final class PRHubFoldUITests: PRHubUITestCase {
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

    /// Where the header's top is, again and again for `seconds`: off screen counts as far away.
    private func sampleTops(of header: XCUIElement, for seconds: TimeInterval) -> [CGFloat] {
        var tops: [CGFloat] = []
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            tops.append(header.exists && header.isHittable ? header.frame.minY : -10000)
            RunLoop.current.run(until: min(end, Date.now.addingTimeInterval(0.05)))
        }
        return tops
    }
}
