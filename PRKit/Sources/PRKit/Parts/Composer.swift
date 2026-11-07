import PRKitDesign
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The reply field: grows to five lines, sends on the arrow, and on the Mac on Return too (Option-Return for a new
/// line). Liquid Glass from the system, nothing custom behind it; the field is plain, so the Mac draws no box of its
/// own inside the glass.
/// `focused` is the screen's, so a scroll or a tap in the content can put the keyboard away (`dismissesKeyboard`).
public struct SessionComposer: View {
    /// From the field's bottom up to the middle of its last line: its padding and half a line.
    @ScaledMetric(relativeTo: .body) private var lineMiddle = 20.0
    @Binding public var draft: String
    public let isSending: Bool
    public let send: () -> Void
    public var placeholder = "Reply"
    public let focused: FocusState<Bool>.Binding

    public init(
        draft: Binding<String>, isSending: Bool, send: @escaping () -> Void, placeholder: String = "Reply",
        focused: FocusState<Bool>.Binding
    ) {
        _draft = draft
        self.isSending = isSending
        self.send = send
        self.placeholder = placeholder
        self.focused = focused
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        HStack(alignment: .sendButton, spacing: Space.sm) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(focused)
                .lineLimit(1...5)
                .padding(ChatStyle.fieldInsets)
                .glassEffect(in: .rect(cornerRadius: 20, style: .continuous))
                .submitLabel(.send)
                .sendsOnReturn {
                    if canSend {
                        send()
                    }
                }
                .alignmentGuide(.sendButton) { field in
                    #if os(macOS)
                    field[.lastTextBaseline]
                    #else
                    field[.bottom] - lineMiddle
                    #endif
                }
                .accessibilityIdentifier("sessionReplyField")
            Button(action: send) {
                // The arrow stays, hidden, while sending: its baseline is the one the Mac lines the button up by.
                Image(systemName: "arrow.up")
                    .font(.appBody.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .opacity(isSending ? 0 : 1)
                    .overlay {
                        if isSending {
                            ProgressView()
                        }
                    }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .accessibilityLabel("Send reply")
            .accessibilityIdentifier("sessionReplySend")
        }
        .readableBarWidth()
    }
}

/// A message field's place above the keyboard or the tab bar: clear of what is behind it, with more room under it
/// while the keyboard is up. The page shows through glass as clashing text, so the bar has its own backing, which
/// fades in over the page above it. The keyboard's own notifications say when it is up: the screen's focus state
/// did not change for a field in a `safeAreaBar` (seen in the Simulator, iOS 26.5).
private struct ComposerBar: ViewModifier {
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal)
            .padding(.top, ChatStyle.barFade)
            .padding(.bottom, keyboardUp ? Space.lg : Space.sm)
            .background {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.groundPage.opacity(0), Color.groundPage],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: ChatStyle.barFade)
                    Color.groundPage
                }
                .ignoresSafeArea(edges: .bottom)
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            #endif
    }
}

extension View {
    public func composerBar() -> some View {
        modifier(ComposerBar())
    }
}
