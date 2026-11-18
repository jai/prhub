#if os(macOS)
    import PRKitDesign
    import SwiftUI
    import Testing

    /// The Mac's own type sizes (DESIGN.md `x-mac-typography`) and how View → Make Text Bigger scales them.
    @Suite(.serialized)
    struct MacTextSizeTests {
        @Test func actualSizeIsTheMacTable() {
            let defaults = UserDefaults.standard
            let kept = defaults.object(forKey: MacTextSize.key)
            defer { defaults.set(kept, forKey: MacTextSize.key) }
            defaults.removeObject(forKey: MacTextSize.key)
            #expect(MacTextSize.scale == MacTextSize.standard)
            #expect(MacTextSize.points(.body) == DesignTokens.macStyles[.body]?.size)
            defaults.set(1.2, forKey: MacTextSize.key)
            #expect(MacTextSize.points(.footnote) == (DesignTokens.macStyles[.footnote]?.size ?? 0) * 1.2)
        }

        @Test func layoutKeepsItsSizeBesideTheText() {
            let ratio = Double((DesignTokens.macStyles[.body]?.size ?? 0) / (DesignTokens.styles[.body]?.size ?? 1))
            #expect(abs(MacTextSize.layoutScale - MacTextSize.scale * ratio) < 0.0001)
        }
    }
#endif
