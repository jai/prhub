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
    /// A control while pressed, and while it can't be used.
    public static let pressedOpacity = 0.7
    public static let disabledOpacity = 0.4
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
}

/// A chip of state words (`StatusChip`).
public enum ChipStyle {
    public static let horizontal = Space.sm
    public static let vertical: CGFloat = 3
    /// The tint's strength behind the words.
    public static let groundOpacity = 0.15
}
