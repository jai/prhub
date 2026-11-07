import CoreGraphics

/// When the phone's nav bar and tab bar leave the diff and when they come back. They leave as a finger scrolls down the
/// code and come back as it scrolls up, and they never stay gone when scrolling up can't bring them back: at the top,
/// or with nothing to scroll, say once a fold has made the diff shorter than the screen.
enum DiffBars {
    /// What to do with the bars.
    enum Decision: Equatable {
        case show, hide, keep
    }

    /// The list as it stands, in its own points: `offset` is `contentOffset.y`, which is `-topInset` at the very top.
    struct Scroll: Equatable {
        var offset: CGFloat
        /// How far the list went since the bars last answered: positive down the code.
        var moved: CGFloat
        var contentHeight: CGFloat
        var visibleHeight: CGFloat
        var topInset: CGFloat
        var bottomInset: CGFloat
        /// A finger dragging or flinging. A jump to a key line or a fold moving the list never hides the bars.
        var byFinger: Bool
        /// The keyboard holds the bars away while a comment is written; it brings them back as it goes.
        var isKeyboardUp = false

        var top: CGFloat {
            -topInset
        }

        /// The furthest the list scrolls down. Past it is the bounce, which runs back up without the reader going back.
        var bottom: CGFloat {
            contentHeight + bottomInset - visibleHeight
        }
    }

    /// How far a drag runs before the bars answer it, so a resting thumb doesn't flicker them.
    static let dragThreshold: CGFloat = 8

    static func decide(_ scroll: Scroll) -> Decision {
        guard !scroll.isKeyboardUp else {
            return .keep
        }
        // Nothing to scroll, or nothing above: scrolling up could never bring them back.
        if scroll.bottom <= scroll.top + dragThreshold || scroll.offset <= scroll.top + dragThreshold {
            return .show
        }
        guard scroll.byFinger, scroll.offset < scroll.bottom, abs(scroll.moved) >= dragThreshold else {
            return .keep
        }
        if scroll.moved < 0 {
            return .show
        }
        // Not before the code has passed the top: the top inset shrinking there would pull the list down under the
        // finger, which reads as going back up, and the bars would flicker.
        return scroll.offset > 0 ? .hide : .keep
    }
}
