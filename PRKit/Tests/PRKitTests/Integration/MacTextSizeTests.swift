#if os(macOS)
    import PRKitDesign
    import SwiftUI
    import Testing

    /// The Mac's own type sizes (DESIGN.md `x-mac-typography`) and how View → Make Text Bigger scales them.
    struct MacTextSizeTests {
        @Test func actualSizeIsTheMacTable() {
            let preferences = TestPreferences()
            defer { withExtendedLifetime(preferences) {} }
            let defaults = preferences.defaults
            defaults.removeObject(forKey: MacTextSize.key)
            #expect(MacTextSize.scale(in: defaults) == MacTextSize.standard)
            #expect(MacTextSize.points(.body, defaults: defaults) == DesignTokens.macStyles[.body]?.size)
            defaults.set(1.2, forKey: MacTextSize.key)
            #expect(MacTextSize.points(.footnote, defaults: defaults) == (DesignTokens.macStyles[.footnote]?.size ?? 0) * 1.2)
        }

        @Test func layoutKeepsItsSizeBesideTheText() {
            let preferences = TestPreferences()
            defer { withExtendedLifetime(preferences) {} }
            let defaults = preferences.defaults
            defaults.set(1.35, forKey: MacTextSize.key)
            let ratio = Double((DesignTokens.macStyles[.body]?.size ?? 0) / (DesignTokens.styles[.body]?.size ?? 1))
            #expect(abs(MacTextSize.layoutScale(in: defaults) - MacTextSize.scale(in: defaults) * ratio) < 0.0001)
        }
    }
#endif
