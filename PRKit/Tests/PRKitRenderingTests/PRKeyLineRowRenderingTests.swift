import Foundation
@testable import PRKit
import SwiftUI
import Testing

/// A key line in the diff's panel, drawn off screen in light and dark (DESIGN.md, A key line). Each one is a card on the
/// list's page with a band of that page before the next, so one row ends where the next begins (Jai, 2026-11-25:
/// "There's no separation between the lines"); and its tick is the circle a file's viewed mark is, not a square.
@MainActor
struct PRKeyLineRowRenderingTests {
    private static let width: CGFloat = 340
    private static let scale: CGFloat = 2

    private static func row(_ line: Int, isReviewed: Bool = false) -> PRKeyLineRow {
        PRKeyLineRow(
            item: PRKeyLines.Item(
                path: "src/checkout/a/long/way/down/the/tree/CheckoutErrorBoundary.tsx", line: line, side: "RIGHT",
                kind: "risk", why: "If retryPayment throws, retrying stays true and the button stays disabled."
            ),
            isSelected: false, isReviewed: isReviewed, show: {}, explain: {}, setReviewed: { _ in }
        )
    }

    private func render(_ view: some View, width: CGFloat? = Self.width, in scheme: ColorScheme) throws -> Bitmap {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, scheme))
        renderer.scale = Self.scale
        // Drawn until two draws in a row are the same and not empty: a process's first draw can come back unfinished
        // (PRRowCardRenderingTests, 2026-11-25).
        var last = try Bitmap(#require(renderer.cgImage))
        for _ in 0 ..< 5 {
            let next = try Bitmap(#require(renderer.cgImage))
            if next.bytes == last.bytes, next.bytes.contains(where: { $0 != 0 }) {
                return next
            }
            last = next
        }
        Issue.record("the view did not draw the same twice, or drew nothing")
        return last
    }

    private func pixel(_ points: CGFloat) -> Int {
        Int((points * Self.scale).rounded())
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func eachKeyLineIsACardWithABandOfThePageBeforeTheNext(_ scheme: ColorScheme) throws {
        let list = VStack(spacing: Space.sm) {
            Self.row(9)
            Self.row(12)
        }
        .padding(.horizontal, PRStyle.inset)
        .background(Color.groundList)
        let bitmap = try render(list, in: scheme)

        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let page = Pixel(Color.groundList.resolve(in: environment))
        let card = Pixel(Color.groundCard.resolve(in: environment))
        #expect(card.distance(to: page) >= 24, "a card's ground \(card) is a step off the page \(page)")
        #expect(bitmap[pixel(PRStyle.inset / 2), bitmap.height / 4].isNear(page), "beside a card is the page")

        // Down the far edge of a card, past its corner and clear of its words and controls: a card, the page, a card.
        let column = (0 ..< bitmap.height).map { bitmap[bitmap.width - pixel(PRStyle.inset + Radius.md + Space.xxs), $0] }
        var bands: [Range<Int>] = []
        var start: Int?
        for (index, pixel) in column.enumerated() {
            if pixel.isNear(page), index > self.pixel(Radius.md), index < column.count - self.pixel(Radius.md) {
                start = start ?? index
            } else if let from = start {
                bands.append(from ..< index)
                start = nil
            }
        }
        #expect(bands.count == 1, "one band of the page, between the two cards: \(bands)")
        #expect(abs((bands.first?.count ?? 0) - pixel(Space.sm)) <= 2, "the band is Space.sm: \(bands)")
    }

    /// The tick's ink, open: a ring. A square inks its box's corners; a circle leaves them and its middle clear.
    @Test(arguments: [ColorScheme.light, .dark])
    func theTickIsACircleAFingerWide(_ scheme: ColorScheme) throws {
        let tick = PRKeyLineCheck(isReviewed: false, toggle: {}, identifier: "tick").background(Color.groundCard)
        let bitmap = try render(tick, width: nil, in: scheme)
        #expect(bitmap.width >= pixel(PRStyle.rowHeight) && bitmap.height >= pixel(PRStyle.rowHeight), "44 pt to tap")

        let ground = bitmap[0, 0]
        var inked: [(column: Int, row: Int)] = []
        for row in 0 ..< bitmap.height {
            for column in 0 ..< bitmap.width where bitmap[column, row].distance(to: ground) >= 60 {
                inked.append((column, row))
            }
        }
        let columns = inked.map(\.column), rows = inked.map(\.row)
        let left = try #require(columns.min()), right = try #require(columns.max())
        let top = try #require(rows.min()), bottom = try #require(rows.max())
        #expect(abs((right - left) - (bottom - top)) <= 2, "as wide as it is tall")
        for corner in [(left, top), (right, top), (left, bottom), (right, bottom)] {
            #expect(bitmap[corner.0, corner.1].distance(to: ground) < 60, "a circle's box has clear corners: \(corner)")
        }
        #expect(bitmap[(left + right) / 2, (top + bottom) / 2].distance(to: ground) < 60, "and an open one is a ring")
    }

    /// Ticking a line fades its words and moves nothing.
    @Test func tickingALineMovesNothing() throws {
        let open = try render(Self.row(9), in: .dark)
        let ticked = try render(Self.row(9, isReviewed: true), in: .dark)
        #expect(open.width == ticked.width && open.height == ticked.height)
        // Compared here, not in the expectation: a failure would print every byte of both pictures.
        let looksTicked = open.bytes != ticked.bytes
        #expect(looksTicked, "a ticked line looks ticked")
    }
}
