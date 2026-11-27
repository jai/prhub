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

    private static func row(_ line: Int, isReviewed: Bool = false, explains: Bool = true) -> PRKeyLineRow {
        PRKeyLineRow(
            item: PRKeyLines.Item(
                path: "src/checkout/a/long/way/down/the/tree/CheckoutErrorBoundary.tsx", line: line, side: "RIGHT",
                kind: "risk", why: "If retryPayment throws, retrying stays true and the button stays disabled."
            ),
            isSelected: false, isReviewed: isReviewed, show: {}, explain: explains ? {} : nil, setReviewed: { _ in }
        )
    }

    private func render(_ view: some View, width: CGFloat? = Self.width, in scheme: ColorScheme) throws -> Bitmap {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, scheme))
        renderer.scale = Self.scale
        return try Bitmap(renderer.settledImage())
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

    /// The tick is first in the card, as a file's viewed mark is in Files, and Explain is at the far end, a finger's
    /// width from it at least (Jai, 2026-11-25: "the checkbox could move left"). At the default text size and the
    /// largest, where the controls have a line of their own.
    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func theTickLeadsTheCardAndExplainIsAtItsFarEnd(_ textSize: DynamicTypeSize) throws {
        let tick = try render(
            PRKeyLineCheck(isReviewed: false, toggle: {}, identifier: "tick").background(Color.groundCard)
                .environment(\.dynamicTypeSize, textSize),
            width: nil, in: .dark
        )
        let card = try render(Self.row(9).environment(\.dynamicTypeSize, textSize), in: .dark)
        // The ring's columns: where the tick, drawn alone, has ink across its middle.
        let ring = (0 ..< tick.width).filter { tick[$0, tick.height / 2].distance(to: tick[0, 0]) >= 60 }
        let alone = try (#require(ring.first, "the tick's ring"), #require(ring.last))
        // The same columns have the ring in the card's heading, and nothing but the card's edge comes before it.
        let ground = card[tick.width / 2, pixel(Space.xs)]
        let leading = (pixel(Space.xs) ..< tick.width).filter { column in
            (pixel(Radius.md) ..< tick.height).contains { card[column, $0].distance(to: ground) >= 60 }
        }
        let inCard = try (#require(leading.first, "ink where the card starts"), #require(leading.last))
        #expect(abs(inCard.0 - alone.0) <= 2 && abs(inCard.1 - alone.1) <= 2, "the tick is first: \(inCard), \(alone)")

        // Explain: the columns that change when the card has it.
        let without = try render(Self.row(9, explains: false).environment(\.dynamicTypeSize, textSize), in: .dark)
        #expect(card.width == without.width && card.height == without.height, "Explain takes no room of the words'")
        guard card.width == without.width, card.height == without.height else { return }
        let changed = (0 ..< card.width).filter { column in
            (0 ..< card.height).contains { card[column, $0].distance(to: without[column, $0]) >= 24 }
        }
        let first = try #require(changed.first, "a card with Explain shows it")
        #expect(first > card.width / 2, "Explain is at the far end: column \(first) of \(card.width)")
        #expect(first - tick.width >= pixel(PRStyle.rowHeight), "and a finger's width from the tick: \(first)")
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

    /// The sample acme/web#412's first key line as the panel's list draws it, with Copy, Add to review and Explain.
    private static func sampleRow(isAdded: Bool) -> PRKeyLineRow {
        PRKeyLineRow(
            item: PRKeyLines.Item(
                path: "src/checkout/CheckoutError.tsx", line: 9, side: "RIGHT", kind: "risk",
                why: "If retryPayment throws, retrying stays true and the button stays disabled."
            ),
            isSelected: false, isReviewed: false, show: {}, explain: {}, setReviewed: { _ in }, isAdded: isAdded,
            addToReview: {}
        )
    }

    /// The runs of columns with ink in them over `rows` of a card drawn in light, clear of the card's own edge; a run goes on over a gap
    /// narrower than `Space.sm`, which the parts of one icon are and two controls never are.
    private func inkRuns(in bitmap: Bitmap, rows: ClosedRange<Int>) -> [ClosedRange<Int>] {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let ground = Pixel(Color.groundCard.resolve(in: environment))
        let edge = pixel(Space.xs)
        let inked = (edge ..< bitmap.width - edge).filter { column in
            rows.contains { bitmap[column, $0].distance(to: ground) >= 60 }
        }
        var runs: [ClosedRange<Int>] = []
        for column in inked {
            if let last = runs.last, column - last.upperBound < pixel(Space.sm) {
                runs[runs.count - 1] = last.lowerBound ... column
            } else {
                runs.append(column ... column)
            }
        }
        return runs
    }

    /// In the largest text the row's controls have a line of their own under the tick and the kind: beside them they
    /// ran off the card. Drawn as wide as the card is in the phone's panel, which leaves a strip of the page to tap.
    @Test func inTheLargestTextTheControlsAreOnTheCardUnderTheTickEachAFingerWide() throws {
        let largest = DynamicTypeSize.accessibility5
        let card = (402 * 0.86 - PRStyle.inset * 2).rounded(.down)
        let renderer = ImageRenderer(
            content: Self.sampleRow(isAdded: false).frame(width: card).environment(\.dynamicTypeSize, largest)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = Self.scale
        let picture = try renderer.settledImage()
        try Attachment.record(picture.png(), named: "key-line-row-largest.png")
        let open = try Bitmap(picture)
        let added = try render(Self.sampleRow(isAdded: true).environment(\.dynamicTypeSize, largest), width: card, in: .light)
        #expect(open.width == added.width && open.height == added.height, "adding it to the review moves nothing")
        guard open.width == added.width, open.height == added.height else { return }

        // Add to review's icon is all that changes when the review has the comment: where the two pictures differ.
        let rows = (0 ..< open.height).filter { row in
            (0 ..< open.width).contains { open[$0, row].distance(to: added[$0, row]) >= 24 }
        }
        let columns = (0 ..< open.width).filter { column in
            (0 ..< open.height).contains { open[column, $0].distance(to: added[column, $0]) >= 24 }
        }
        let top = try #require(rows.first, "Add to review looks added"), bottom = try #require(rows.last)
        let left = try #require(columns.first), right = try #require(columns.last)

        // Clear of the tick: under its line, where the tick is the row's first thing.
        let tick = try render(
            PRKeyLineCheck(isReviewed: false, toggle: {}, identifier: "tick").environment(\.dynamicTypeSize, largest),
            width: nil, in: .light
        )
        #expect(top >= tick.height, "Add to review's icon starts \(top) px down, the tick's line is \(tick.height) px")

        // On that line Copy, Add to review and Explain, and nothing else.
        let runs = inkRuns(in: open, rows: top ... bottom)
        #expect(runs.count == 3, "Copy, Add to review, Explain: \(runs)")
        guard runs.count == 3 else { return }
        #expect(runs[1].overlaps(left ... right), "Add to review is the middle one: \(runs), changed \(left) to \(right)")
        // Each is a finger's width, its icon in the middle of it, and all of each is on the card. An icon's ink is
        // not quite in the middle of its own box: a few points either way.
        let middles = runs.map { CGFloat($0.lowerBound + $0.upperBound) / 2 / Self.scale }
        let slack = Space.xs
        for (before, after) in zip(middles, middles.dropFirst()) {
            #expect(after - before >= PRStyle.rowHeight - slack, "a finger's width each: middles at \(middles) pt")
        }
        #expect(middles[0] - PRStyle.rowHeight / 2 >= -slack, "Copy is on the card: middles at \(middles) pt")
        #expect(middles[2] + PRStyle.rowHeight / 2 <= card + slack, "Explain is on the card, \(card) pt wide: \(middles)")
    }
}

/// The note's Reviewed button, drawn off screen ticked and not. Its words are the same either way and only its circle
/// changes (Jai, 2026-11-26: "butons can't change when you click them it should just be \"Reviewed\""). It read
/// "Mark reviewed" until ticked and "Reviewed" after, so a press changed its words and its width.
@MainActor
struct PRKeyLineReviewedButtonRenderingTests {
    private static let scale: CGFloat = 2

    private func render(isReviewed: Bool, iconOnly: Bool = false, in scheme: ColorScheme) throws -> Bitmap {
        let button = PRKeyLineReviewedButton(isReviewed: isReviewed, iconOnly: iconOnly) {}
            .padding(Space.sm)
            .background(Color.groundCard)
            .tint(Color.accentColor)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: button)
        renderer.scale = Self.scale
        return try Bitmap(renderer.settledImage())
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func aPressChangesTheCircleAndNoWords(_ scheme: ColorScheme) throws {
        let open = try render(isReviewed: false, in: scheme)
        let ticked = try render(isReviewed: true, in: scheme)
        #expect(open.width == ticked.width && open.height == ticked.height, "the same size ticked or not")
        guard open.width == ticked.width, open.height == ticked.height else { return }

        // The columns where the two pictures differ: the circle's, and no others.
        let changed = (0 ..< open.width).filter { column in
            (0 ..< open.height).contains { open[column, $0].distance(to: ticked[column, $0]) >= 24 }
        }
        let first = try #require(changed.first, "a ticked button looks ticked"), last = try #require(changed.last)
        // The circle is as tall as the footnote's line at most, and leads; the words after it are far wider.
        let circle = Int(PRStyle.controlHeight * Self.scale)
        #expect(last - first < circle, "only the circle changes: columns \(first) to \(last) of \(open.width)")
        #expect(last < open.width / 2, "and it leads the words, which stay: columns \(first) to \(last)")
    }

    /// In the largest text the button is its circle alone; ticked or not it is the same size there too.
    @Test func theCircleAloneIsTheSameSizeTickedOrNot() throws {
        let open = try render(isReviewed: false, iconOnly: true, in: .dark)
        let ticked = try render(isReviewed: true, iconOnly: true, in: .dark)
        #expect(open.width == ticked.width && open.height == ticked.height)
    }
}
