import PRKitCore
import PRKitDesign
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings' "Diff font": a live preview of a few diff lines drawn by the diff itself, the size, and every face, each
/// name in its own face. One view for every app that embeds PRKit: put it in the app's Settings `Form`.
public struct DiffFontSection: View {
    @AppStorage(diffFontIn: nil) private var diffFont

    public init() {}

    public var body: some View {
        Section {
            DiffFontPreview(font: diffFont)
                .listRowInsets(EdgeInsets())
            Stepper(value: sizeBinding, in: DiffFont.sizes, step: 1) {
                LabeledContent("Size", value: "\(Int(diffFont.size)) pt")
                    .contentTransition(.numericText())
            }
            .accessibilityIdentifier("diff-font-size")
            Picker("Font", selection: faceBinding) {
                ForEach(DiffFontFace.allCases) { face in
                    Text(face.name)
                        .diffFont(DiffFont(face: face, size: Font.appleSize(.body)))
                        .tag(face)
                        .accessibilityIdentifier("diff-font-\(face.rawValue)")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Diff font")
        } footer: {
            Text("Code in diffs and comments. It grows with your text size; a file's name is a step bigger.")
        }
    }

    private var sizeBinding: Binding<CGFloat> {
        Binding(
            get: { diffFont.size },
            set: { size in withAnimation(AppMotion.swap) { diffFont = diffFont.with(size: size) } }
        )
    }

    private var faceBinding: Binding<DiffFontFace> {
        Binding(
            get: { diffFont.face },
            set: { face in withAnimation(AppMotion.swap) { diffFont = diffFont.with(face: face) } }
        )
    }
}

/// A file's header and a few lines, drawn by the real diff table at `font`. Its viewed mark works, so the size of the
/// mark can be tried here.
struct DiffFontPreview: View {
    private static let sample = """
        diff --git a/Sources/Checkout/RetryButton.swift b/Sources/Checkout/RetryButton.swift
        --- a/Sources/Checkout/RetryButton.swift
        +++ b/Sources/Checkout/RetryButton.swift
        @@ -12,3 +12,4 @@ struct CheckoutView: View {
             var body: some View {
        -        Text("Payment failed")
        +        Text("Payment failed, try again")
        +        RetryButton(action: retry)
             }

        """
    private static let document = DiffDocument(data: Data(sample.utf8))
    private static let rows = DiffRows(document: document, threads: [])

    let font: DiffFont
    @State private var viewed: Set<String> = []
    @State private var folds = FoldSet()
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        DiffTableView(
            document: Self.document, rows: Self.rows, viewed: viewed, jump: nil, composing: nil, topInset: 0,
            font: font, onContent: {}, actions: actions
        )
        .frame(height: height)
        .accessibilityIdentifier("diff-font-preview")
    }

    /// Tall enough for the header and every line, open or folded.
    private var height: CGFloat {
        #if os(iOS)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let metrics = DiffMetrics(font, traits: traits)
        #else
        let metrics = DiffMetrics(font)
        #endif
        let lines = Self.rows.files.first?.rows.count ?? 0
        return metrics.fileHeaderHeight + CGFloat(lines) * metrics.rowHeight + Space.sm
    }

    private var actions: DiffActions {
        DiffActions(
            folds: folds,
            setViewed: { isViewed, path in
                viewed = isViewed ? viewed.union([path]) : viewed.subtracting([path])
            },
            openURL: OpenURLAction { _ in .discarded },
            text: { _ in .constant("") },
            replyText: { _ in .constant(nil) },
            compose: { _ in },
            closeNote: {},
            setBarsHidden: { _ in },
            setKeyboardUp: { _ in },
            removeDraft: { _ in },
            reply: { _, _ in },
            setResolved: { _, _ in }
        )
    }
}

extension View {
    /// Code in the device's diff font (`DiffFont`), `step` points bigger, at the text size. A heading over code is
    /// `DiffFont.headingStep` bigger.
    func diffCodeFont(step: CGFloat = 0) -> some View {
        modifier(DiffFontModifier(explicit: nil, step: step))
    }

    /// `font` itself, at the text size: a face's name in Settings.
    func diffFont(_ font: DiffFont) -> some View {
        modifier(DiffFontModifier(explicit: font, step: 0))
    }
}

private struct DiffFontModifier: ViewModifier {
    let explicit: DiffFont?
    let step: CGFloat
    @AppStorage(diffFontIn: nil) private var stored
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #else
    @AppStorage(MacTextSize.key) private var macTextScale = MacTextSize.standard
    #endif

    func body(content: Content) -> some View {
        let font = explicit ?? stored
        #if os(iOS)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let scale = DiffMetrics.textScale(traits)
        #else
        let scale = MacTextSize.scale
        #endif
        return content.font(Font(font.platformFont(points: (font.size + step) * scale) as CTFont))
    }
}
