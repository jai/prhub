import CoreGraphics
import Testing
@testable import PRKit

/// When the diff's bars leave and come back (`DiffBars`): never gone with no scroll to bring them back.
struct DiffBarsTests {
    /// A phone's diff: 116 pt of bars over a 791 pt list, 60 pt under the last line for the floating controls.
    private func scroll(
        offset: CGFloat, moved: CGFloat = 0, content: CGFloat = 3_000, byFinger: Bool = true,
        topInset: CGFloat = 116, isKeyboardUp: Bool = false
    ) -> DiffBars.Scroll {
        DiffBars.Scroll(
            offset: offset, moved: moved, contentHeight: content, visibleHeight: 791, topInset: topInset,
            bottomInset: 60, byFinger: byFinger, isKeyboardUp: isKeyboardUp
        )
    }

    @Test func scrollingDownTheCodeHidesThemAndUpBringsThemBack() {
        #expect(DiffBars.decide(scroll(offset: 400, moved: 20)) == .hide)
        #expect(DiffBars.decide(scroll(offset: 400, moved: -20)) == .show)
    }

    @Test func aRestingThumbMovesNothing() {
        #expect(DiffBars.decide(scroll(offset: 400, moved: 3)) == .keep)
        #expect(DiffBars.decide(scroll(offset: 400, moved: -3)) == .keep)
    }

    @Test func theyStayUntilTheCodeHasPassedTheTop() {
        #expect(DiffBars.decide(scroll(offset: -50, moved: 20)) == .keep)
    }

    @Test func atTheTopTheyAreBack() {
        #expect(DiffBars.decide(scroll(offset: -116, byFinger: false)) == .show)
        #expect(DiffBars.decide(scroll(offset: -110, moved: 10)) == .show)
        // With the bars gone, the top inset is the clock's alone.
        #expect(DiffBars.decide(scroll(offset: -62, byFinger: false, topInset: 62)) == .show)
    }

    /// Jai's diff: its only file folded, the rest of the screen empty, and no scroll to bring the bars back.
    @Test func nothingToScrollBringsThemBack() {
        #expect(DiffBars.decide(scroll(offset: 0, content: 28, byFinger: false, topInset: 62)) == .show)
        #expect(DiffBars.decide(scroll(offset: 300, moved: 20, content: 600)) == .show)
        // Exactly a screen of code.
        #expect(DiffBars.decide(scroll(offset: -116, moved: 20, content: 791 - 60 - 116)) == .show)
    }

    @Test func aJumpDownTheCodeLeavesThemWhereTheyAre() {
        #expect(DiffBars.decide(scroll(offset: 400, moved: 300, byFinger: false)) == .keep)
        #expect(DiffBars.decide(scroll(offset: 400, moved: -300, byFinger: false)) == .keep)
    }

    @Test func theBounceAtTheEndIsNotGoingBack() {
        let bottom: CGFloat = 3_000 + 60 - 791
        #expect(DiffBars.decide(scroll(offset: bottom + 10, moved: -20)) == .keep)
        #expect(DiffBars.decide(scroll(offset: bottom, moved: -20)) == .keep)
    }

    @Test func theKeyboardHoldsThemAway() {
        #expect(DiffBars.decide(scroll(offset: 0, content: 28, byFinger: false, isKeyboardUp: true)) == .keep)
        #expect(DiffBars.decide(scroll(offset: 400, moved: -20, isKeyboardUp: true)) == .keep)
    }
}
