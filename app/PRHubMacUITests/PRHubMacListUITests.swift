import XCTest

/// The Mac's PR list, which no Simulator shows: each PR is a card (DESIGN.md, PR card), and the card under the pointer
/// lifts its ground. How a lifted card looks is drawn and measured off screen (`PRRowCardRenderingTests`); only a real
/// pointer over the app's window shows that a card follows it, and that the card is at rest again once it has left.
///
/// The card of the PR open beside the list has no test here: the Mac's window is one stack, so no PR is open beside
/// its list (`PRsList(model:selected: nil)`); that look is the iPad's split view's.
@MainActor
final class PRHubMacListUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app.terminate()
    }

    /// A PR's line on its card, by its title: on the Mac it is one button, whose label holds the title.
    private func prCard(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// An element as the screen shows it.
    private struct Picture {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ element: XCUIElement) throws {
            let image = try XCTUnwrap(element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// The share of this picture's pixels that are another colour in `other`, 0 to 1. A picture of another size
        /// differs everywhere.
        func share(differingFrom other: Picture) -> Double {
            guard width == other.width, height == other.height, width * height > 0 else {
                return 1
            }
            var differing = 0
            for pixel in 0 ..< width * height {
                let at = pixel * 4
                // More than rounding: the faintest fill moves a channel by several steps.
                if (0 ..< 3).contains(where: { abs(Int(bytes[at + $0]) - Int(other.bytes[at + $0])) >= 3 }) {
                    differing += 1
                }
            }
            return Double(differing) / Double(width * height)
        }
    }

    /// How much of `element` differs from `rest`, looked at until `holds` or 3 seconds: a card's lift is animated.
    private func share(of element: XCUIElement, differingFrom rest: Picture, until holds: (Double) -> Bool) throws -> Double {
        var share = try Picture(element).share(differingFrom: rest)
        for _ in 0 ..< 15 where !holds(share) {
            Thread.sleep(forTimeInterval: 0.2)
            share = try Picture(element).share(differingFrom: rest)
        }
        return share
    }

    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The red of a past-SLA mark (`tone-bad`, light or dark) in the card's avatar column, under the avatar: how many
    /// of the picture's pixels there are red. The column is the card's leading 32 pt, which no other red reaches: a
    /// failing check's words are in the text column.
    private func redUnderTheAvatar(of card: XCUIElement) throws -> Int {
        let picture = try Picture(card)
        let scale = Double(picture.width) / Double(card.frame.width)
        let columns = 0 ..< min(picture.width, Int(32 * scale))
        let rows = min(picture.height, Int(32 * scale)) ..< picture.height
        var red = 0
        for row in rows {
            for column in columns {
                let at = (row * picture.width + column) * 4
                let (r, g, b) = (Int(picture.bytes[at]), Int(picture.bytes[at + 1]), Int(picture.bytes[at + 2]))
                if r >= 150, r - max(g, b) >= 80 {
                    red += 1
                }
            }
        }
        return red
    }

    /// Jai, 2026-11-25: "We lost the SLA overdue red clock in PR Hub, it seems, in the list of PRs. I can't tell which
    /// are over SLA." A review past its SLA has the red clock and its age under its avatar, on its card; one not yet
    /// due has none. The samples hold one of each.
    func testAReviewPastItsSLAHasTheRedClockUnderItsAvatarOnItsCard() throws {
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let late = prCard("Rate-limit the password reset endpoint")
        let onTime = prCard("Show a retry button when checkout fails")
        XCTAssertTrue(late.waitForExistence(timeout: 30), "the sample review that is 26 hours past its SLA")
        XCTAssertTrue(onTime.exists, "the sample review asked 3 hours ago")
        app.activate()
        // The pointer off every card, so neither is lifted.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 14)).hover()
        var red = try redUnderTheAvatar(of: late)
        for _ in 0 ..< 15 where red < 40 {
            Thread.sleep(forTimeInterval: 0.2)
            red = try redUnderTheAvatar(of: late)
        }
        picture("past-sla-clock")
        XCTAssertTrue(late.label.contains("Past review SLA"), "the card says it is past its SLA: \(late.label)")
        XCTAssertGreaterThanOrEqual(red, 40, "the red clock and its age are drawn under the late review's avatar")
        XCTAssertEqual(try redUnderTheAvatar(of: onTime), 0, "a review not yet due has no clock")
        XCTAssertFalse(onTime.label.contains("Past review SLA"), "nor says so: \(onTime.label)")
    }

    func testTheCardUnderThePointerLiftsItsGroundAndRestsAgainOffIt() throws {
        // No windows of an earlier run: the launch opens the PRs window alone. First, so it is read as a pair.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-PRHubPaired"]
        app.launch()
        let card = prCard("Keep the cart when the app is closed")
        let other = prCard("Show a retry button when checkout fails")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "a PR's card in the list")
        XCTAssertTrue(other.exists, "another PR's card")
        app.activate()

        // The pointer off every card: on the window's title bar.
        let away = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 14))
        away.hover()
        var rest = try Picture(card)
        // At rest once two looks agree: the list has stopped arriving.
        for _ in 0 ..< 15 {
            Thread.sleep(forTimeInterval: 0.2)
            let next = try Picture(card)
            let moved = next.share(differingFrom: rest)
            rest = next
            if moved < 0.01 {
                break
            }
        }
        let otherAtRest = try Picture(other)

        card.hover()
        let lifted = try share(of: card, differingFrom: rest) { $0 > 0.5 }
        picture("card-under-the-pointer")
        XCTAssertGreaterThan(lifted, 0.5, "under the pointer, a card's ground lifts")
        XCTAssertLessThan(
            try Picture(other).share(differingFrom: otherAtRest), 0.05, "only the card under the pointer lifts"
        )

        away.hover()
        let left = try share(of: card, differingFrom: rest) { $0 < 0.05 }
        XCTAssertLessThan(left, 0.05, "once the pointer has left, the card is at rest again")
    }
}
