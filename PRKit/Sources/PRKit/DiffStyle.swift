import PRKitCore
import PRKitDesign
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The diff's colours and fixed measures, the same on the phone's table and the Mac's (`Phone/`, `Mac/`). What follows
/// the font is `DiffMetrics`.
enum DiffStyle {
    static let threadInset: CGFloat = 8
    static let selectedLine = PlatformColor.systemYellow.withAlphaComponent(0.32)

    static func background(_ kind: DiffDocument.Kind) -> PlatformColor {
        switch kind {
        case .added: .systemGreen.withAlphaComponent(0.18)
        case .removed: .systemRed.withAlphaComponent(0.18)
        case .hunk: .systemBlue.withAlphaComponent(0.14)
        case .file, .meta, .context: .clear
        }
    }
}

/// The diff's measures at a font and text size: the code, the file header one step bigger, and a header row that holds
/// a 44 pt viewed mark on the phone.
struct DiffMetrics {
    /// Apple's smallest tap target.
    static let minimumTapTarget: CGFloat = 44
    private static let rowPadding: CGFloat = 2
    private static let headerPadding = Space.sm

    let font: DiffFont
    let scale: CGFloat
    let code: PlatformFont
    let headerPath: PlatformFont
    let headerChange: PlatformFont
    let rowHeight: CGFloat
    let fileHeaderHeight: CGFloat
    /// One character of the code.
    let columnWidth: CGFloat
    let viewedSymbolSize: CGFloat
    let viewedTarget: CGFloat
    let chevronSymbolSize: CGFloat

    /// `scale` is the text size's: Dynamic Type's on the phone, View → Make Text Bigger's on the Mac.
    init(_ font: DiffFont, scale: CGFloat) {
        self.font = font
        self.scale = scale
        let codeSize = font.size * scale
        let headerSize = (font.size + DiffFont.headingStep) * scale
        code = font.platformFont(points: codeSize)
        headerPath = font.platformFont(points: headerSize, isBold: true)
        headerChange = .monospacedDigitSystemFont(ofSize: headerSize, weight: .medium)
        rowHeight = ceil(code.diffLineHeight) + Self.rowPadding
        #if os(iOS)
        viewedTarget = max(Self.minimumTapTarget, ceil(headerPath.diffLineHeight) + Self.headerPadding * 2)
        #else
        viewedTarget = ceil(headerPath.diffLineHeight) + Self.headerPadding * 2
        #endif
        fileHeaderHeight = viewedTarget
        columnWidth = ("M" as NSString).size(withAttributes: [.font: code]).width
        viewedSymbolSize = (headerSize * 1.05).rounded()
        chevronSymbolSize = (headerSize * 0.8).rounded()
    }

    /// The file header's path for `text` in `width`: the header's size when it fits, else smaller, down to the code's
    /// size (a heading is never smaller than what it heads). A path still too long is cut from the front.
    func headerPath(fitting text: String, in width: CGFloat) -> PlatformFont {
        var fitted = headerPath
        while fitted.pointSize > code.pointSize,
              (text as NSString).size(withAttributes: [.font: fitted]).width > width {
            fitted = font.platformFont(points: max(fitted.pointSize - 1, code.pointSize), isBold: true)
        }
        return fitted
    }

    #if os(iOS)
    init(_ font: DiffFont, traits: UITraitCollection) {
        self.init(font, scale: Self.textScale(traits))
    }

    /// Dynamic Type's scale for body text at `traits`' text size: 1 at the default, Large.
    static func textScale(_ traits: UITraitCollection) -> CGFloat {
        let reference: CGFloat = 100
        return UIFontMetrics.default.scaledValue(for: reference, compatibleWith: traits) / reference
    }
    #else
    init(_ font: DiffFont) {
        self.init(font, scale: MacTextSize.codeScale)
    }
    #endif
}

extension PlatformFont {
    /// One line's height, the same on UIKit and AppKit.
    var diffLineHeight: CGFloat {
        #if os(iOS)
        lineHeight
        #else
        ascender - descender + leading
        #endif
    }
}

/// What the table can ask for. It holds these, not the session, so it only ever sees a diff and rows.
struct DiffActions {
    /// Which files and threads Jai has folded: it lives in the session, so it outlasts a switch of page.
    let folds: FoldSet
    let setViewed: (Bool, String) -> Void
    /// Hosted cells don't inherit SwiftUI's environment, and a PR link in a thread must stay in the app.
    let openURL: OpenURLAction
    let text: (DiffDocument.Line) -> Binding<String>
    let replyText: (PullRequestDetail.Thread) -> Binding<String?>
    /// A line was picked to comment on, or nil to stop. The box itself is the screen's, above the keyboard.
    let compose: (Int?) -> Void
    let closeNote: () -> Void
    /// The noted key line's tick, read by the note itself so a tick made in the panel shows under the line too.
    let isReviewed: (PRKeyLines.Item) -> Bool
    let setReviewed: (PRKeyLines.Item, Bool) -> Void
    /// Ask AI about a key line; nil when Ask is off.
    let explain: ((PRKeyLines.Item) -> Void)?
    /// The reader scrolled down the code (true) or back up. The phone's bars go and come with it.
    let setBarsHidden: (Bool) -> Void
    let setKeyboardUp: (Bool) -> Void
    let removeDraft: (PRDraftComment) -> Void
    let reply: (PullRequestDetail.Thread, String) async throws -> Void
    let setResolved: (PullRequestDetail.Thread, Bool) async throws -> Void
    /// The file at the top of the screen, by index, as the reader scrolls.
    let showsFileOnTop: (Int) -> Void
}
