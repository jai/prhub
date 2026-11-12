/// When the message field moves the keyboard: only when the screen's `focused` changes, never because it merely
/// disagrees. On iOS 26.5 a screen's focus state can stay off while the field is first responder (a composer with no
/// attachments never turned it on), and pushing that off value into UIKit closed the keyboard after the first letter.
/// Such a screen can't put the keyboard away through `focused` either, since setting it off changes nothing: it
/// needs a way that doesn't go through focus, such as `scrollDismissesKeyboard`.
enum ChatFieldFocus: Equatable {
    case take
    case give

    /// `last` is the `focused` the field saw at its previous update, `nil` at its first.
    static func move(wants: Bool, last: Bool?, isFirstResponder: Bool) -> Self? {
        guard wants != last else {
            return nil
        }
        if wants {
            return isFirstResponder ? nil : .take
        }
        // At the first update, off only says nothing has asked for the keyboard yet.
        return last == nil || !isFirstResponder ? nil : .give
    }
}

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
    /// Return and Command-Return on a hardware keyboard (`ReturnKey`).
    let send: () -> Void

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
        view.send = send
        view.accessibilityLabel = placeholder
        let wantsFocus = focused.wrappedValue
        let move = ChatFieldFocus.move(
            wants: wantsFocus, last: context.coordinator.lastFocused, isFirstResponder: view.isFirstResponder
        )
        context.coordinator.lastFocused = wantsFocus
        if let move {
            // After this update: a view not yet in a window can't take the keyboard.
            let coordinator = context.coordinator
            Task { @MainActor in
                if move == .give {
                    _ = view.resignFirstResponder()
                } else if !view.becomeFirstResponder() {
                    // Not taken: the next update asks again.
                    coordinator.lastFocused = nil
                }
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
        /// `focused` at the previous update, so only a change of it moves the keyboard (`ChatFieldFocus`).
        var lastFocused: Bool?

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

/// A text view whose Paste takes a picture when the clipboard holds pictures and no words, and whose Return on a
/// hardware keyboard sends (`ReturnKey`).
final class PictureTextView: UITextView {
    var pastePicture: (@MainActor @Sendable (Data) -> Void)?
    var send: (() -> Void)?

    /// Hardware keys only: the on-screen keyboard's return key types a new line as always. Ahead of the text view's
    /// own Return, which would type one.
    override var keyCommands: [UIKeyCommand]? {
        let flags: [UIKeyModifierFlags] = [[], .command, .shift, .alternate]
        let returns = flags.map { flags in
            let command = UIKeyCommand(input: "\r", modifierFlags: flags, action: #selector(returnPressed(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + returns
    }

    @objc func returnPressed(_ command: UIKeyCommand) {
        var modifiers: ReturnKey.Modifiers = []
        if command.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if command.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if command.modifierFlags.contains(.command) { modifiers.insert(.command) }
        switch ReturnKey.action(modifiers) {
        case .send: send?()
        case .newLine: insertText("\n")
        }
    }

    private var clipboardHasOnlyPictures: Bool {
        pastePicture != nil && UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), clipboardHasOnlyPictures {
            return true
        }
        // The text view refuses actions it does not know, which would disable the Return commands and swallow the key.
        if action == #selector(returnPressed(_:)) {
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
