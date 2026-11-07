import SwiftUI

/// DESIGN.md's icon-and-words line: the icon in a slot of one width, at least, whose leading edge is the text column's, on
/// the words' first line, `Space.xs` before the words. Every line of an icon and words is drawn by this, so their icons
/// line up with the text above them and with each other. Use `Label(…).labelStyle(.iconText)` or `IconText`.
public struct IconTextLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        IconTextLine(icon: configuration.icon, words: configuration.title)
    }
}

extension LabelStyle where Self == IconTextLabelStyle {
    public static var iconText: IconTextLabelStyle { IconTextLabelStyle() }
}

/// An icon from `AppIcon` and words, as `IconTextLabelStyle` draws them.
public struct IconText: View {
    let text: String
    let icon: AppIcon

    public init(_ text: String, icon: AppIcon) {
        self.text = text
        self.icon = icon
    }

    public var body: some View {
        Label(text, systemImage: icon.symbol)
            .labelStyle(.iconText)
    }
}

private struct IconTextLine<Icon: View, Words: View>: View {
    let icon: Icon
    let words: Words
    /// The slot grows with the text, as the icon does.
    @ScaledMetric(relativeTo: .footnote) private var slot = Space.lg

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            // A wider icon takes the room it needs rather than running into the words.
            icon
                .fixedSize()
                .frame(minWidth: slot, alignment: .leading)
                .accessibilityHidden(true)
            words
        }
    }
}

/// The columns every row shares (DESIGN.md, Layout): a leading column of one width, then the text. A row's title starts
/// at the same place on every row whatever leads it, an avatar or an icon.
public enum RowGrid {
    public static let leading: CGFloat = 32
    public static let gutter: CGFloat = 12
}

/// A row's leading icon, centred in the leading column, so a wide icon never moves the title.
public struct LeadingIcon: View {
    let icon: AppIcon
    let tint: Color
    @ScaledMetric(relativeTo: .subheadline) private var width = RowGrid.leading

    public init(_ icon: AppIcon, tint: Color) {
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        Image(icon)
            .font(.appTitle3)
            .foregroundStyle(tint)
            .frame(width: width)
    }
}
