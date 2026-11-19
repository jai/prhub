#if os(macOS)
    import PRKitDesign
    import SwiftUI
    import Testing

    /// The Mac's own type sizes (DESIGN.md `x-mac-typography`) and how View → Make Text Bigger scales them.
    struct MacTextSizeTests {
        @Test func actualSizeIsTheMacTable() {
            #expect(MacTextSize.scale(stored: 0) == MacTextSize.standard, "nothing stored")
            #expect(MacTextSize.scale(stored: 1.25) == MacTextSize.standard, "not one of the scales")
            let actual = MacTextSize.scale(stored: 0)
            #expect(MacTextSize.points(.body, scale: actual) == DesignTokens.macStyles[.body]?.size)
            let bigger = MacTextSize.scale(stored: 1.2)
            #expect(MacTextSize.points(.footnote, scale: bigger) == (DesignTokens.macStyles[.footnote]?.size ?? 0) * 1.2)
        }

        @Test func layoutKeepsItsSizeBesideTheText() {
            let scale = MacTextSize.scale(stored: 1.35)
            let ratio = Double((DesignTokens.macStyles[.body]?.size ?? 0) / (DesignTokens.styles[.body]?.size ?? 1))
            #expect(abs(MacTextSize.layoutScale(scale: scale) - scale * ratio) < 0.0001)
        }
    }
#endif
