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
    /// A tone's strength behind the thing it colours: a chip's words, a PR's state icon.
    public static let toneGroundOpacity = 0.15
}

/// A chat's bubble and field (`SessionBubble`, `SessionComposer`).
public enum ChatStyle {
    /// Words from the bubble's edge.
    public static let bubbleInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    /// Words from the field's edge.
    public static let fieldInsets = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
    /// The room a bubble leaves on the other side, so whose it is reads at a glance.
    public static let otherSide: CGFloat = 48
    public static let radius = Radius.lg
    /// The fade over the page above the field's bar, and the room it leaves over the field.
    public static let barFade: CGFloat = 14
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
}
