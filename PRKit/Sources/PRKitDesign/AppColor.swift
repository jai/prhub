import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Every colour the screens draw with, by role (DESIGN.md, Color). Views use these, never a colour of their own.
///
/// Tones are DESIGN.md's colour sets, which the host ships (`make -C app design` writes PRHub's). Text, grounds, fills and
/// lines are the system's: they follow Increase Contrast and lift a step inside a sheet, which a colour set can't. Their
/// DESIGN.md tokens hold the same values; to brand one, point its line here at the colour set (`Color("GroundPage")`).
public extension Color {
    // States: GitHub's, light and dark.
    static var toneGood: Color {
        Color("ToneGood")
    }

    static var toneBad: Color {
        Color("ToneBad")
    }

    static var toneWaiting: Color {
        Color("ToneWaiting")
    }

    static var toneMerged: Color {
        Color("ToneMerged")
    }

    /// Text, and quiet text (meta, a count, what someone did).
    static var ink: Color {
        .primary
    }

    static var inkQuiet: Color {
        .secondary
    }

    /// Words and spinners on the accent or a tone: a primary button, a swipe action. White
    /// in light; black in dark, where the tones are bright enough that white on them fails contrast (DESIGN.md,
    /// `on-accent`).
    static var onAccent: Color {
        #if os(iOS)
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        #else
            Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white })
        #endif
    }

    /// Words on the person's own chat bubble: white in light and dark, Jai's call over `onAccent`'s contrast rule
    /// (DESIGN.md, `on-bubble`).
    static var onBubble: Color {
        .white
    }

    /// The page, and a block or box on it. Both, always: `.background` is black on black in dark.
    static var groundPage: Color {
        #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
        #else
            Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var groundCard: Color {
        #if os(iOS)
            Color(uiColor: .secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The page under a list whose rows are cards (`PRRowCard`). On the Mac the window and a block on it are one
    /// colour (`groundPage` and `groundCard` are both #1E1E1E in dark, white in light), so a band of the page between
    /// two blocks can't be seen there: the list's page is its own (DESIGN.md, `ground-list-mac`), and a card lifts
    /// off it. Everywhere else it is the page.
    static var groundList: Color {
        #if os(iOS)
            .groundPage
        #else
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(opaque: isDark ? ColorTokens.groundListMacDark : ColorTokens.groundListMac)
            })
        #endif
    }

    /// Over a card's ground under the pointer, and under the one that is open: the system's faintest fill, so a
    /// tone's words keep their contrast on it.
    static var groundHover: Color {
        #if os(iOS)
            Color(uiColor: .quaternarySystemFill)
        #else
            Color(nsColor: .quaternarySystemFill)
        #endif
    }

    /// Behind a field or a quiet button.
    static var groundFill: Color {
        #if os(iOS)
            Color(uiColor: .tertiarySystemFill)
        #else
            Color(nsColor: .tertiarySystemFill)
        #endif
    }

    /// A hairline: a box's border, a divider.
    static var line: Color {
        #if os(iOS)
            Color(uiColor: .separator)
        #else
            Color(nsColor: .separatorColor)
        #endif
    }

    /// The dim over a page under a side panel, at its full strength.
    static var scrim: Color {
        .black.opacity(0.3)
    }
}

#if os(macOS)
    private extension NSColor {
        /// A colour token (`ColorTokens`, 0xRRGGBB) as an opaque sRGB colour.
        convenience init(opaque token: UInt32) {
            self.init(
                srgbRed: CGFloat((token >> 16) & 0xFF) / 255, green: CGFloat((token >> 8) & 0xFF) / 255,
                blue: CGFloat(token & 0xFF) / 255, alpha: 1
            )
        }
    }
#endif
