import Foundation
@testable import PRKit
import PRKitDesign
import SwiftUI
import Testing

/// The PR's own description, as its page draws it (`PRCommentText` in the page's card): a long paragraph and a link
/// with no break in it wrap in the card's width, so nothing of them is off the screen's sides. A wide table and wide
/// code scroll sideways in their own room (DESIGN.md, Markdown), and do not widen the card either.
@MainActor
struct PRLongDescriptionTests {
    /// The card's room on a phone: the screen less the page's margins and the card's own.
    private static let room = LongLineTable.phoneWidth - Space.lg * 2 - PRStyle.inset * 2

    /// What the description takes when offered `width`.
    private static func size(of text: String, in width: CGFloat) -> CGSize {
        let view = PRCommentText(PRMarkdown.clean(text))
        let offered = CGSize(width: width, height: 100_000)
        #if os(iOS)
            return UIHostingController(rootView: view).sizeThatFits(in: offered)
        #else
            return NSHostingController(rootView: view).sizeThatFits(in: offered)
        #endif
    }

    @Test func aLongParagraphAndALinkWrapInTheCardsWidth() {
        let narrow = Self.size(of: LongLineSample.description, in: Self.room)
        let wide = Self.size(of: LongLineSample.description, in: Self.room * 4)
        #expect(narrow.width <= Self.room + 0.5, "nothing is off the sides: \(narrow.width) pt in \(Self.room)")
        // Text that did not wrap, or that scrolled sideways, would be as tall in a narrow room as in a wide one.
        #expect(narrow.height > wide.height * 2, "it wraps: \(narrow.height) pt tall in the card, \(wide.height) in four times the room")
    }

    @Test func aWideTableAndWideCodeDoNotWidenTheCard() {
        let whole = LongLineSample.description + "\n\n" + LongLineSample.wideBlocks
        let size = Self.size(of: whole, in: Self.room)
        #expect(size.width <= Self.room + 0.5, "\(size.width) pt in \(Self.room)")
        #expect(size.height > Self.size(of: LongLineSample.description, in: Self.room).height, "the table and the code are under it")
    }
}
