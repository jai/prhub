import PRKitDesign
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The reply field: grows to five lines, sends on the arrow, and on the Mac on Return too (Option-Return for a new
/// line). Liquid Glass from the system, nothing custom behind it; the field is plain, so the Mac draws no box of its
/// own inside the glass.
/// `focused` is the screen's, so a scroll or a tap in the content can put the keyboard away (`dismissesKeyboard`).
/// With `attachments`, a paperclip beside the field adds screenshots from Photos or Files, a Paste button shows while the
/// clipboard holds a picture (and on the Mac Command-V in the field attaches it), and the tray above the field shows
/// them; a message may then be screenshots alone.
public struct SessionComposer: View {
    /// From the field's bottom up to the middle of its last line: its padding and half a line.
    @ScaledMetric(relativeTo: .body) private var lineMiddle = 20.0
    @Binding public var draft: String
    public let isSending: Bool
    public let send: () -> Void
    public var placeholder = "Reply"
    public let focused: FocusState<Bool>.Binding
    public let attachments: ComposerAttachments?
    @State private var clipboard = ClipboardWatch()
    @Environment(\.scenePhase) private var scenePhase

    public init(
        draft: Binding<String>, isSending: Bool, send: @escaping () -> Void, placeholder: String = "Reply",
        focused: FocusState<Bool>.Binding, attachments: ComposerAttachments? = nil
    ) {
        _draft = draft
        self.isSending = isSending
        self.send = send
        self.placeholder = placeholder
        self.focused = focused
        self.attachments = attachments
    }

    private var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments?.isEmpty == false)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let attachments {
                ComposerAttachmentTray(attachments: attachments, canPaste: clipboard.hasPicture && !attachments.isFull)
            }
            field
        }
        .readableBarWidth()
        .onAppear { clipboard.check() }
        .onChange(of: focused.wrappedValue) { clipboard.check() }
        .onChange(of: scenePhase) { clipboard.check() }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboard.check()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboard.check()
        }
        .modifier(OptionalCommandV(attachments: attachments, isActive: focused.wrappedValue))
        #endif
    }

    private var field: some View {
        HStack(alignment: .sendButton, spacing: Space.sm) {
            if let attachments {
                ComposerAttachButton(attachments: attachments)
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(focused)
                .lineLimit(1...5)
                .padding(ChatStyle.fieldInsets)
                .glassEffect(in: .rect(cornerRadius: ChatStyle.radius, style: .continuous))
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
    }
}

#if os(macOS)
private struct OptionalCommandV: ViewModifier {
    let attachments: ComposerAttachments?
    let isActive: Bool

    func body(content: Content) -> some View {
        if let attachments {
            content.modifier(CommandVPictures(attachments: attachments, isActive: isActive))
        } else {
            content
        }
    }
}
#endif

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
