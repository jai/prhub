import UIKit
import XCTest

/// A PR's page scrolled under its title: none of the page's words can be read there. Jai's picture (2026-11-26, an
/// iPad, the PR beside the list): the description had scrolled up under the title, and neither could be read. Each
/// check scrolls the top of the page up under the bar a little at a time, and after each step measures the picture
/// beside the title, where the page's words pass: it stays one flat colour. In light and dark, and in the largest text.
@MainActor
final class PRKitTopBarUITests: PRHubUITestCase {
    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"
    /// How far apart the lightest and darkest points beside the title may be, of 1: words there are 0.078 and more, a
    /// solid bar 0.024 at most.
    private static let flat = 0.04

    func testNoWordsShowUnderThePRsTitle() throws {
        try wordsUnderTheTitle("light", appearance: .light, textSize: nil)
    }

    func testNoWordsShowUnderThePRsTitleInDark() throws {
        try wordsUnderTheTitle("dark", appearance: .dark, textSize: nil)
    }

    func testNoWordsShowUnderThePRsTitleInTheLargestText() throws {
        try wordsUnderTheTitle("largest-light", appearance: .light, textSize: Self.largest)
    }

    private func wordsUnderTheTitle(_ name: String, appearance: XCUIDevice.Appearance, textSize: String?) throws {
        // An iPad on its side: upright, the sample PR's page is shorter than a 13-inch screen and scrolls nowhere.
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launch(
            ["-PRHubPaired", "-prhubAlertsDeclined", "YES"]
                + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []),
            appearance: appearance
        )
        app.openPR("Show a retry button when checkout fails")
        let files = app.buttons["pr-files-changed"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        let bar = app.navigationBars["acme/web#412"]
        let title = bar.staticTexts["acme/web#412"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the PR's title in its bar")
        app.waitForStill(files)
        recordScreenshot("top-bar-\(name)-1-top")

        // Beside the title, clear of the bar's buttons and their shadows: before it on an iPad, where it is centred;
        // after it on a phone, where it follows Back.
        let window = app.windows.firstMatch
        let buttons = bar.buttons.allElementsBoundByIndex.map(\.frame).filter { $0.width > 0 }
        let leading = buttons.filter { $0.maxX <= title.frame.minX }.map(\.maxX).max() ?? 0
        let trailing = buttons.filter { $0.minX >= title.frame.maxX }.map(\.minX).min() ?? files.frame.maxX
        let gap = [
            (max(files.frame.minX, leading) + 8, title.frame.minX - 8),
            (title.frame.maxX + 8, min(files.frame.maxX, trailing) - 24),
        ].first { $0.1 - $0.0 >= 30 }
        // A phone's title in the largest text fills the bar from Back to the buttons: nothing beside it to measure.
        try XCTSkipIf(gap == nil && !app.isWide, "\(name): the title fills a phone's bar; an iPad's run measures this")
        let (from, upTo) = try XCTUnwrap(gap, "\(name): room beside the title to look at")
        let beside = CGRect(x: from, y: title.frame.minY, width: upTo - from, height: title.frame.height)

        // The page's heading, then Files changed, up under the title, a little at a time.
        let top = files.frame.midY
        let finger = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: files.frame.midX, dy: window.frame.height * 0.6))
        var worst = 0.0
        for _ in 0 ..< 14 where files.exists && files.frame.midY > title.frame.midY {
            finger.press(
                forDuration: 0.05, thenDragTo: finger.withOffset(CGVector(dx: 0, dy: -40)), withVelocity: .slow,
                thenHoldForDuration: 0.4
            )
            let picture = XCUIScreen.main.screenshot()
            let spread = try spread(in: beside, of: picture.image, screen: window.frame.size)
            if spread > worst {
                worst = spread
                let attachment = XCTAttachment(screenshot: picture)
                attachment.name = "top-bar-\(name)-2-most-under-the-title"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        recordScreenshot("top-bar-\(name)-3-scrolled")
        print("TOPBAR \(name) worst=\(worst) beside=\(beside)")
        let moved = files.exists ? top - files.frame.midY : .infinity
        XCTAssertGreaterThanOrEqual(moved, 80, "\(name): the page's heading has scrolled up under the title")
        XCTAssertLessThanOrEqual(
            worst, Self.flat, "\(name): the page's words show beside the title, where they have scrolled under it"
        )
    }

    /// How far apart the lightest and darkest points in `rect` of the screen's `picture` are, of 1, leaving out the odd
    /// point in a hundred at each end.
    private func spread(in rect: CGRect, of picture: UIImage, screen: CGSize) throws -> Double {
        let width = Int(rect.width), height = Int(rect.height)
        var points = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(
            data: &points, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        // The picture as the screen shows it, whichever way up the device is, one point of grey per screen point.
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        picture.draw(in: CGRect(x: -rect.minX, y: -rect.minY, width: screen.width, height: screen.height))
        UIGraphicsPopContext()
        let sorted = points.sorted()
        let cut = sorted.count / 100
        return Double(sorted[sorted.count - 1 - cut] - sorted[cut]) / 255
    }
}
