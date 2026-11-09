#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's message field. A UIKit text view, because only a text view of its own can offer Paste for a picture:
/// with `pastePicture`, Paste with a picture and no words on the clipboard hands each picture over; words paste as
/// always. Grows to `maxLines`, then scrolls, and keeps `focused` and the keyboard in step both ways.
struct ChatTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focused: FocusState<Bool>.Binding
    let maxLines: Int
    let pastePicture: (@MainActor @Sendable (Data) -> Void)?

    func makeUIView(context: Context) -> PictureTextView {
        let view = PictureTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.accessibilityIdentifier = "sessionReplyField"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PictureTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        view.pastePicture = pastePicture
        view.accessibilityLabel = placeholder
        let wantsFocus = focused.wrappedValue
        if wantsFocus != view.isFirstResponder {
            // After this update: a view not yet in a window can't take the keyboard.
            Task { @MainActor in
                _ = wantsFocus ? view.becomeFirstResponder() : view.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PictureTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return nil
        }
        let line = view.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let most = ceil(line * CGFloat(maxLines))
        let fit = ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        view.isScrollEnabled = fit > most
        return CGSize(width: width, height: min(max(fit, ceil(line)), most))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatTextView

        init(parent: ChatTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused.wrappedValue {
                parent.focused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused.wrappedValue {
                parent.focused.wrappedValue = false
            }
        }
    }
}

/// A text view whose Paste takes a picture when the clipboard holds pictures and no words.
final class PictureTextView: UITextView {
    var pastePicture: (@MainActor @Sendable (Data) -> Void)?

    private var clipboardHasOnlyPictures: Bool {
        pastePicture != nil && UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), clipboardHasOnlyPictures {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard clipboardHasOnlyPictures, let pastePicture else {
            super.paste(sender)
            return
        }
        // A copied photo is a promise until it is loaded, so its bytes come from its item provider.
        for provider in UIPasteboard.general.itemProviders
        where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else {
                    return
                }
                Task { @MainActor in pastePicture(data) }
            }
        }
    }
}
#endif
