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

/// A chat's bubble and field (`SessionBubble`, `SessionComposer`).
public enum ChatStyle {
    /// Words from the bubble's edge.
    public static let bubbleInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    /// Words from the field's edge.
    public static let fieldInsets = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
    /// The room a bubble leaves on the other side, so whose it is reads at a glance.
    public static let otherSide: CGFloat = 48
    /// The most of a wide chat's width a bubble takes, so on an iPad or a Mac window it stays a bubble, never a page.
    /// A chat narrower than `shareFrom` (a phone) only keeps `otherSide`.
    public static let widestShare: CGFloat = 0.75
    public static let shareFrom: CGFloat = 480
    public static let radius = Radius.lg
    /// How far down an attachment open full screen is swiped to close it.
    public static let viewerDismissDrag: CGFloat = 120
    /// The fade over the page above the field's bar, and the room it leaves over the field.
    public static let barFade: CGFloat = 14
    /// A screenshot waiting to go with the message, above the field, and the button that takes it off.
    public static let attachmentSize: CGFloat = 64
    public static let attachmentRemove: CGFloat = 22
    /// How far the second delivery tick sits over the first: half a glyph, so the two read as one mark (Jai,
    /// 2026-11-14: at a quarter the edges only touched).
    public static let tickOverlap: CGFloat = -6
    /// How near the end of a chat counts as reading it, so a new message keeps the reader there.
    public static let followSlack: CGFloat = 40
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

/// What people write, laid out (`MarkdownText`).
public enum MarkdownStyle {
    /// Between a list's marker or checkbox and its words.
    public static let markerGap: CGFloat = 6
    /// A nested list's step in, per level.
    public static let indent: CGFloat = 18
    /// A quote's words from its bar, and the bar's width.
    public static let quoteInset: CGFloat = 10
    public static let quoteBar: CGFloat = 3
    /// A table cell's widest, before its words wrap; a table wider than the text scrolls sideways.
    public static let tableCellMaxWidth: CGFloat = 240
    /// An image's tallest, so a screenshot in a description doesn't take the whole screen.
    public static let imageMaxHeight: CGFloat = 360
}
