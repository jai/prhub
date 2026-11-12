#if os(macOS)
import PRKitDesign
import SwiftUI
import Testing

/// The Mac's own type sizes (DESIGN.md `x-mac-typography`) and how View → Make Text Bigger scales them.
@Suite(.serialized)
struct MacTextSizeTests {
    private static let styles: [Font.TextStyle] = [
        .largeTitle, .title, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote, .caption, .caption2,
    ]

    @Test func everyStyleHasAMacSizeNothingUnderEleven() {
        for style in Self.styles {
            let size = DesignTokens.macStyles[style]?.size
            #expect(size != nil, "\(style) has no Mac size")
            #expect((size ?? 0) >= 11, "\(style) is under 11 pt on the Mac")
        }
    }

    @Test func macWeightsAreThePhones() {
        for style in Self.styles {
            #expect(DesignTokens.macStyles[style]?.weight == DesignTokens.styles[style]?.weight)
        }
    }

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
