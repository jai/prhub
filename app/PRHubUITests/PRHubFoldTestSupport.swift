import XCTest

@MainActor
extension PRHubUITestCase {
    /// The three-file PR's diff, scrolled into its second file until that file's header stays put: pinned.
    func openSecondFilePinned() -> XCUIElement {
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
            guard header.exists, header.isHittable else {
                last = nil
                continue
            }
            app.waitForStill(header)
            let top = header.frame.minY
            if let last, abs(top - last) <= 1, !app.buttons["file-header-0"].isHittable {
                return header
            }
            last = top
        }
        XCTFail("the second file's header never pinned")
        return header
    }
}
