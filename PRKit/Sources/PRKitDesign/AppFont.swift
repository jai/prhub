import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The app's text styles, from DESIGN.md's `typography` (DesignTokens): one family, and a size and weight per style.
/// On iPhone each follows Settings → Display & Brightness → Text Size, and with the system font at Apple's sizes it is
/// exactly the system's Dynamic Type style. The Mac has no text size an app can follow — its Accessibility → Text Size
/// reaches Apple's own apps only — so there each style is its Mac size (`x-mac-typography`, `DesignTokens.macStyles`)
/// times `MacTextSize.scale`, which View → Make Text Bigger and Make Text Smaller change.
extension Font {
    public static var appLargeTitle: Font { app(.largeTitle) }
    public static var appTitle2: Font { app(.title2) }
    public static var appTitle3: Font { app(.title3) }
    public static var appHeadline: Font { app(.headline) }
    public static var appSubheadline: Font { app(.subheadline) }
    public static var appBody: Font { app(.body) }
    public static var appCallout: Font { app(.callout) }
    public static var appFootnote: Font { app(.footnote) }
    public static var appCaption: Font { app(.caption) }
    public static var appCaption2: Font { app(.caption2) }

    public static func app(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font {
        let family = design == .monospaced ? DesignTokens.codeFontFamily : DesignTokens.fontFamily
        #if os(macOS)
        let token = DesignTokens.macStyles[style] ?? DesignTokens.Style(size: 14, weight: .regular)
        let size = token.size * MacTextSize.scale
        if let family {
            return .custom(family, fixedSize: size).weight(weight ?? token.weight)
        }
        return .system(size: size, weight: weight ?? token.weight, design: design)
        #else
        let token = DesignTokens.styles[style] ?? DesignTokens.Style(size: 17, weight: .regular)
        if let family {
            return .custom(family, size: token.size, relativeTo: style).weight(weight ?? token.weight)
        }
        if token.size == appleSize(style) {
            return .system(style, design: design, weight: weight ?? defaultWeight(token, style))
        }
        let scaled = UIFontMetrics(forTextStyle: style.uiKit).scaledValue(for: token.size)
        return .system(size: scaled, weight: weight ?? token.weight, design: design)
        #endif
    }

    /// The system's own weight for a style is left to it, so an unchanged token draws exactly the system style.
    private static func defaultWeight(_ token: DesignTokens.Style, _ style: TextStyle) -> Weight? {
        let systemWeight: Weight = style == .headline ? .semibold : .regular
        return token.weight == systemWeight ? nil : token.weight
    }

    /// The iPhone's point sizes at its default text size, Large.
    public static func appleSize(_ style: TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

#if os(iOS)
private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
#endif

#if os(macOS)
/// The Mac's text size: a scale on the Mac's sizes (`DesignTokens.macStyles`), kept between launches. 1 is Actual Size.
public enum MacTextSize {
    public static let key = "macTextScale"
    public static let standard = 1.0
    public static let scales = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5]

    /// The stored scale, or `standard` when none is stored or it is not one of `scales`.
    public static var scale: Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return scales.contains(stored) ? stored : standard
    }

    public static func points(_ style: Font.TextStyle) -> CGFloat {
        (DesignTokens.macStyles[style]?.size ?? 14) * scale
    }

    /// For what is sized beside the text in iPhone points (an avatar, a mark): the Mac's body over the iPhone's, times
    /// the chosen scale, so it keeps its size next to the words.
    public static var layoutScale: Double {
        let mac = DesignTokens.macStyles[.body]?.size ?? 14
        let phone = DesignTokens.styles[.body]?.size ?? 17
        return scale * Double(mac / phone)
    }

    /// For code, whose size is the diff font's in iPhone points: the Mac's code size over the iPhone's, times the scale.
    public static var codeScale: Double {
        scale * Double(DesignTokens.macCodeFontSize / DesignTokens.codeFontSize)
    }

    public static func bigger(than scale: Double) -> Double? {
        scales.first { $0 > scale }
    }

    public static func smaller(than scale: Double) -> Double? {
        scales.last { $0 < scale }
    }
}

/// View → Make Text Bigger (⌘=), Make Text Smaller (⌘−) and Actual Size (⌘0).
public struct MacTextSizeCommands: Commands {
    @AppStorage(MacTextSize.key) private var scale = MacTextSize.standard

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") {
                scale = MacTextSize.bigger(than: scale) ?? scale
            }
            .keyboardShortcut("=")
            .disabled(MacTextSize.bigger(than: scale) == nil)
            Button("Make Text Smaller") {
                scale = MacTextSize.smaller(than: scale) ?? scale
            }
            .keyboardShortcut("-")
            .disabled(MacTextSize.smaller(than: scale) == nil)
            Button("Actual Size") {
                scale = MacTextSize.standard
            }
            .keyboardShortcut("0")
            .disabled(scale == MacTextSize.standard)
        }
    }
}
#endif
