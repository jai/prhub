import SwiftUI

/// The measures of the PR screens' parts that are not one spacing step: each one's only home, so a change to it is one
/// line here (DESIGN.md, Layout). A part's padding, gap and corner come from `Space`, `Radius` and these, never a number
/// typed in a view.
public enum PRStyle {
    /// Words from a box's edge, on every side.
    public static let inset = Space.md
    public static let cardRadius = Radius.md
    public static let controlRadius = Radius.sm
    public static let controlHeight: CGFloat = 32
    /// Words from the sides of a button in a bar of equal buttons (`PRReviewBar`): as close as they come before the bar
    /// shows its icons instead.
    public static let barButtonInset = Space.xs
    /// A row that is one tap target: the least a finger needs.
    public static let rowHeight: CGFloat = 44
    /// Between the lines of PRs and tickets something names (`ObjectReferenceLines`).
    public static let referenceGap: CGFloat = 6
    /// Between lines of what people write: a review tool's dense text, with room to read.
    public static let bodyLineSpacing: CGFloat = 3
    /// Above and below a reviewer's or a check's line inside the status box.
    public static let listRowPadding: CGFloat = 5
    /// A box's border and a ring.
    public static let hairline: CGFloat = 0.5
    /// A focused field's ring.
    public static let focusRing: CGFloat = 1
    /// A control while pressed, and while it can't be used.
    public static let pressedOpacity = 0.7
    public static let disabledOpacity = 0.4
    /// Something done with that stays to be read again: a key line checked off as reviewed.
    public static let doneOpacity = 0.45
    /// A tone's strength behind the thing it colours: a chip's words, a PR's state icon.
    public static let toneGroundOpacity = 0.15
}

/// The panel beside a diff (`sidePanel`, and its column on a wide screen).
public enum PanelStyle {
    /// Over the page: its width where the page is wide. On a phone it leaves a strip of the page to tap.
    public static let width: CGFloat = 380
    /// Beside the diff, where there is room: the diff keeps at least `diffWidth`.
    public static let columnWidth: CGFloat = 340
    public static let diffWidth: CGFloat = 640
}

/// The review's toast at the top of the PRs tab (`PRReviewToastView`).
public enum ToastStyle {
    /// Its widest, so on an iPad or a Mac it stays a toast, never a banner.
    public static let maxWidth: CGFloat = 480
    /// How long it stays once GitHub has the review, before it fades.
    public static let dwell = Duration.seconds(2)
    /// It floats over the nav bar and the page: a soft shadow lifts it off both, where glass let their words show
    /// through its own.
    public static let shadowOpacity = 0.15
    public static let shadowRadius: CGFloat = 12
    public static let shadowY: CGFloat = 4
    /// How far above its place it slides in from and out to: past the top of the screen, so it never appears in mid-air.
    public static let travel: CGFloat = 160
    /// The bar along its foot that fills as the review goes.
    public static let progressHeight: CGFloat = 3
    /// How far the bar fills while GitHub has not answered: the rest waits on its answer.
    public static let progressWhileSending = 0.85
    /// The bar easing towards `progressWhileSending`, slowing as it nears it.
    public static let progressMotion = Animation.easeOut(duration: 4)
}

/// A chip of state words (`StatusChip`).
public enum ChipStyle {
    public static let horizontal = Space.sm
    public static let vertical: CGFloat = 3
}
