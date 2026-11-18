#if os(macOS)
    import PRKitDesign
    import SwiftUI
    import Testing

    struct MacTypeScaleTests {
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
    }
#endif
