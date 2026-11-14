import PRKitDesign
import SwiftUI

/// One line of a chat, as `ChatView` draws it. A host turns its own conversation into these: a thread's transcript
/// and replies in Agent Pager, a PR's Ask AI chat in PRHub.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Jai's: on the right, in the accent, as he typed it.
        case mine
        /// The agent's: on the left, in Markdown.
        case theirs
        /// A tool the agent called: one quiet line, its name and a summary.
        case tool(name: String?)
    }

    public let id: String
    public var role: Role
    public var text: String
    /// Under the bubble, when it has no ticks.
    public var date: Date?
    /// Beside the date: the line a question was about, say.
    public var footnote: String?
    /// How far one of his got; `nil` while it is on its way or failed, where the host says so in its extras.
    public var ticks: DeliveryTicks?
    /// Something of the host's hangs under it (`ChatView`'s `extras`): the bubble is then drawn again with the page,
    /// where a bare one is drawn again only when it changes.
    public var hasExtras: Bool

    public init(
        id: String, role: Role, text: String, date: Date? = nil, footnote: String? = nil,
        ticks: DeliveryTicks? = nil, hasExtras: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.footnote = footnote
        self.ticks = ticks
        self.hasExtras = hasExtras
    }
}

/// The one chat screen: a thread in Agent Pager, Ask AI on a PR. Its messages oldest first, opening at the end and
/// keeping the reader there as an answer grows it (`followsChatEnd`); a tap on the chat puts the keyboard away; the
/// host's field in a bar at the foot. Change how a chat looks or scrolls here, once, and both apps have it.
///
/// What only one host has goes in its slots: `header` over the messages (Load earlier), `extras` under a message
/// (a question's answers, a reply's status, screenshots), `footer` under the last (the agent at work, a failure),
/// `composer` at the foot.
public struct ChatView<Extras: View, Header: View, Footer: View, Composer: View>: View {
    let messages: [ChatMessage]
    /// Said where the messages go while there are none.
    var emptyText: String?
    /// Changes with each message Jai sends (a count of them, the newest's id): the chat goes to the end with it.
    let sent: AnyHashable
    @Binding var readsEnd: Bool
    var isLoadingEarlier: Bool
    var focus: FocusState<Bool>.Binding
    @ViewBuilder let extras: (ChatMessage) -> Extras
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let composer: () -> Composer

    public init(
        messages: [ChatMessage], emptyText: String? = nil, sent: AnyHashable, readsEnd: Binding<Bool>,
        isLoadingEarlier: Bool = false, focus: FocusState<Bool>.Binding,
        @ViewBuilder extras: @escaping (ChatMessage) -> Extras,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder footer: @escaping () -> Footer,
        @ViewBuilder composer: @escaping () -> Composer
    ) {
        self.messages = messages
        self.emptyText = emptyText
        self.sent = sent
        _readsEnd = readsEnd
        self.isLoadingEarlier = isLoadingEarlier
        self.focus = focus
        self.extras = extras
        self.header = header
        self.footer = footer
        self.composer = composer
    }

    private static var end: String { "chatEnd" }

    public var body: some View {
        ScrollViewReader { proxy in
            ChatScroll {
                // A plain stack, not a lazy one: the chat keeps to its end by its content's height, which a lazy
                // stack only estimates, so a long answer left the page somewhere in its middle.
                VStack(alignment: .leading, spacing: Space.sm) {
                    header()
                    if messages.isEmpty, let emptyText {
                        Text(emptyText)
                            .font(.appFootnote)
                            .foregroundStyle(.secondary)
                            .padding(PRStyle.inset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(messages) { message in
                        row(message)
                            .transition(.fold)
                    }
                    footer()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.end)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .animation(AppMotion.fold, value: messages)
            }
            .followsChatEnd(proxy, endID: Self.end, readsEnd: $readsEnd, isLoadingEarlier: isLoadingEarlier, sent: sent)
            .dismissesKeyboard(focus)
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
        .safeAreaBar(edge: .bottom) { composer() }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case let .tool(name):
            ChatToolLine(name: name, text: message.text)
                .equatable()
        case .mine, .theirs:
            if message.hasExtras {
                ChatBubble(message: message) { extras(message) }
            } else {
                ChatBubble(message: message) { EmptyView() }
                    .equatable()
            }
        }
    }
}

/// A message's bubble, its ticks, and what the host hangs under it.
private struct ChatBubble<Under: View>: View {
    let message: ChatMessage
    @ViewBuilder let under: () -> Under

    var body: some View {
        let isMine = message.role == .mine
        SessionBubble(
            title: nil, text: message.text, date: message.ticks == nil ? message.date : nil, isMine: isMine,
            footnote: message.ticks == nil ? message.footnote : nil
        ) {
            if let ticks = message.ticks {
                DeliveryTicksLine(ticks: ticks, date: message.date, about: message.text)
            }
            under()
        }
    }
}

/// With nothing under it, drawn again only when the message changes: an agent's bubble parses its Markdown as it is
/// made, and parsing every bubble again on each read stalled the main thread on a long chat.
extension ChatBubble: Equatable where Under == EmptyView {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message }
}

/// A tool call: its name and a one-line summary, quiet, in the bubbles' column.
private struct ChatToolLine: View, Equatable {
    let name: String?
    let text: String

    var body: some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                if let name {
                    Text(name)
                        .font(.appCaption.monospaced())
                }
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } icon: {
            Image(AppIcon.toolCall)
                .imageScale(.small)
        }
        .labelStyle(.iconText)
        .font(.appCaption)
        .foregroundStyle(Color.inkQuiet)
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
