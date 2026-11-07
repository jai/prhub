// Generated from DESIGN.md by app/Tools/design/generate.mjs. Do not edit: change DESIGN.md and run make -C app design.
// swiftlint:disable all
import SwiftUI

/// DESIGN.md's tokens. Colours are the asset catalogue's colour sets, written by the same run.
public enum DesignTokens {
    /// Every text style's family; `nil` is the system font.
    public static let fontFamily: String? = nil
    /// Code and diffs; `nil` is the system's monospaced font.
    public static let codeFontFamily: String? = nil
    public static let codeFontSize: CGFloat = 12

    public struct Style: Sendable {
        public let size: CGFloat
        public let weight: Font.Weight

        public init(size: CGFloat, weight: Font.Weight) {
            self.size = size
            self.weight = weight
        }
    }

    /// Each Dynamic Type style at the default text size.
    public static let styles: [Font.TextStyle: Style] = [
        .largeTitle: Style(size: 34, weight: .regular),
        .title: Style(size: 28, weight: .regular),
        .title2: Style(size: 22, weight: .regular),
        .title3: Style(size: 20, weight: .regular),
        .headline: Style(size: 17, weight: .semibold),
        .subheadline: Style(size: 15, weight: .regular),
        .body: Style(size: 17, weight: .regular),
        .callout: Style(size: 16, weight: .regular),
        .footnote: Style(size: 13, weight: .regular),
        .caption: Style(size: 12, weight: .regular),
        .caption2: Style(size: 11, weight: .regular),
    ]

    /// Applied to every SF Symbol from the app's root.
    public static let iconVariant: SymbolVariants = .none
}

/// Space between and around things (DESIGN.md `spacing`).
public enum Space {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
}

/// Corners (DESIGN.md `rounded`).
public enum Radius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
}
