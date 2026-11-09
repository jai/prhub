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
extension Color {
    // States: GitHub's, light and dark.
    public static var toneGood: Color { Color("ToneGood") }
    public static var toneBad: Color { Color("ToneBad") }
    public static var toneWaiting: Color { Color("ToneWaiting") }
    public static var toneMerged: Color { Color("ToneMerged") }

    /// Text, and quiet text (meta, a count, what someone did).
    public static var ink: Color { .primary }
    public static var inkQuiet: Color { .secondary }
    /// Words and spinners on the accent or a tone: a primary button, a swipe action. White
    /// in light; black in dark, where the tones are bright enough that white on them fails contrast (DESIGN.md,
    /// `on-accent`).
    public static var onAccent: Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
        #else
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white })
        #endif
    }
    /// Words on the person's own chat bubble: white in light and dark, Jai's call over `onAccent`'s contrast rule
    /// (DESIGN.md, `on-bubble`).
    public static var onBubble: Color { .white }

    /// The page, and a block or box on it. Both, always: `.background` is black on black in dark.
    public static var groundPage: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    public static var groundCard: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// Behind a field or a quiet button.
    public static var groundFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }

    /// A hairline: a box's border, a divider.
    public static var line: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    /// The dim over a page under a side panel, at its full strength.
    public static var scrim: Color { .black.opacity(0.3) }
}
