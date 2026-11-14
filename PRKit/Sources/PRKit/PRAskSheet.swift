import PRKitCore
import PRKitDesign
import SwiftUI

/// Asking the PR's AI agent, which has the repo at this PR's head and can only read it. A sheet, since it is a real detour:
/// at half height the diff stays in sight. One conversation per PR, kept by the session, so it is here next time.
struct PRAskSheet: View {
    @Bindable var session: PRSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isWriting: Bool

    /// The chat's, then the question on its way, until the chat has it.
    private var messages: [PRAskChat.Message] {
        let sent = session.askChat?.messages ?? []
        guard let question = session.askSend.question,
              sent.last(where: \.isJai)?.text != question.question else {
            return sent
        }
        let anchor = question.anchor.map { "\($0.path):\($0.line)" }
        return sent + [PRAskChat.Message(id: "pending", role: "you", text: question.question, anchor: anchor)]
    }
    /// Whether Jai was reading the end of the chat when he last scrolled it: a new message then keeps him there.
    @State private var readsEnd = true
    /// How many questions the chat shows: one more is one he sent, and the sheet goes to the end with it.
    private var asked: Int { messages.count(where: \.isJai) }
    /// The agent at work on a question it has. A question still on its way says so instead.
    private var isWorking: Bool { session.askSend == .idle && session.askChat?.isWorking == true }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ChatScroll {
                    // A plain stack, not a lazy one: the chat keeps to its end by its content's height, which a lazy
                    // stack only estimates, so a long answer left the sheet somewhere in its middle.
                    VStack(alignment: .leading, spacing: Space.sm) {
                        if messages.isEmpty, !isWorking, session.askSend == .idle {
                            Text("Ask about this PR. The AI reads the whole repo at this PR's head, and can't change anything.")
                                .font(.appFootnote)
                                .foregroundStyle(.secondary)
                                .padding(PRStyle.inset)
                                // The sheet's width, not the lazy stack's first measure: on an iPad that was a phone's.
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // By place: the question drawn on its way becomes the chat's own message, with no fold out and
                        // back in, which left the sheet scrolled past it.
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, item in
                            message(item, at: index).transition(.fold)
                        }
                        status.id(Self.end)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .animation(AppMotion.fold, value: messages)
                    .animation(AppMotion.fold, value: isWorking)
                    .animation(AppMotion.swap, value: session.askSend)
                }
                // Reading the end, he stays with it as an answer grows it; scrolled up, he stays where he is.
                .followsChatEnd(proxy, endID: Self.end, readsEnd: $readsEnd, sent: asked)
                .dismissesKeyboard($isWriting)
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .background(Color.groundPage)
            .safeAreaBar(edge: .bottom) { composer }
            .inlineNavigationTitle()
            .navigationTitle(Text(verbatim: "\(session.ref.repo.split(separator: "/").last ?? "")#\(session.ref.number)"))
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Follows from each send too: a question sets the agent working after the first read has ended.
        .task(id: session.askChat?.isWorking == true || session.isSendingAsk || session.askSend.isOnItsWay) {
            await session.followAsk()
        }
        .presentedScrollMargins()
        .askSheetSize()
        // Only when there is nothing yet: words from a line's box are already on their way.
        .onAppear { isWriting = messages.isEmpty && session.askDraft.isEmpty && session.askSend == .idle }
    }

    private static let end = "end"

    /// A message as every chat draws it; a question about a line names the line under it. Under his questions, how
    /// far each got (`DeliveryTicks`); under the agent's newest answer, "Wait, what?".
    private func message(_ message: PRAskChat.Message, at index: Int) -> some View {
        SessionBubble(
            title: nil, text: message.isJai ? ChatQuickReply.shown(message.text) : message.text, date: nil,
            isMine: message.isJai, footnote: message.anchor
        ) {
            if let ticks = ticks(at: index) {
                DeliveryTicksLine(ticks: ticks, date: nil, about: message.text)
            }
            if canWaitWhat, index == messages.count - 1 {
                WaitWhatButton(isSending: session.isSendingAsk) { waitWhat() }
                    .padding(.leading, Space.md)
                    .accessibilityIdentifier("pr-ask-wait-what")
            }
        }
    }

    /// How far his question at `index` got: one tick once the Worker has it, two once the agent has it, as working on
    /// it or answering it shows. None while it is on its way, or when it could not reach the agent.
    private func ticks(at index: Int) -> DeliveryTicks? {
        let message = messages[index]
        guard message.isJai, message.id != "pending" else {
            return nil
        }
        if messages[(index + 1)...].contains(where: { !$0.isJai }) {
            return .delivered
        }
        guard index == messages.count - 1, session.askSend == .idle, session.askChat?.unsentQuestion == nil else {
            return nil
        }
        return isWorking ? .delivered : .sent
    }

    /// The agent's answer is the chat's newest word and nothing is on its way: he can ask for it again, plainly.
    private var canWaitWhat: Bool {
        guard let last = messages.last else {
            return false
        }
        return !last.isJai && !isWorking && session.askSend == .idle
    }

    @ViewBuilder private var status: some View {
        switch session.askSend {
        case .sending:
            quietMark("Sending…", icon: .sending)
                .accessibilityIdentifier("pr-ask-sending")
        case .waitingForNetwork:
            quietMark("Will send when you're online", icon: .offline)
                .accessibilityIdentifier("pr-ask-offline")
        case let .failed(_, reason):
            failure(reason)
        case .idle:
            chatStatus
        }
    }

    /// Where a question on its way stands: grey, as the chat's own progress is. Nothing is wrong yet.
    private func quietMark(_ words: String, icon: AppIcon) -> some View {
        IconText(words, icon: icon)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words)
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, PRStyle.inset)
            .transition(.fold)
    }

    /// Why a question didn't go, and the way to send it again.
    /// The reason is the Worker's own, technical (side, status, words, turn id): selectable, to paste to an agent.
    private func failure(_ reason: String) -> some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            Text(reason)
                .font(.appFootnote)
                .foregroundStyle(Color.toneBad)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .accessibilityIdentifier("pr-ask-failed-reason")
            HStack(spacing: Space.sm) {
                Button("Edit", systemImage: AppIcon.compose.symbol) { editFailed() }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .accessibilityIdentifier("pr-ask-edit")
                Button("Retry", systemImage: AppIcon.refresh.symbol) { retry() }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .accessibilityIdentifier("pr-ask-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, PRStyle.inset)
        .transition(.fold)
        .accessibilityIdentifier("pr-ask-failed")
    }

    @ViewBuilder private var chatStatus: some View {
        if isWorking {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(session.askChat?.activity ?? "Thinking")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PRStyle.inset)
            .accessibilityIdentifier("pr-ask-working")
        } else if let problem = session.askChat?.problem {
            if session.askChat?.unsentQuestion != nil {
                failure(problem)
            } else {
                Text(problem)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .padding(.horizontal, PRStyle.inset)
            }
        } else if let cents = session.askChat?.costCents, !messages.isEmpty {
            Text("\((Double(cents) / 100).formatted(.currency(code: "USD"))) so far, of $2")
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PRStyle.inset)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let anchor = session.askAnchor {
                HStack(spacing: Space.sm) {
                    Text(verbatim: "\(anchor.path):\(anchor.line)")
                        .font(.app(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Ask about the whole PR", systemImage: AppIcon.close.symbol) { session.askAboutWholePR() }
                        .labelStyle(.iconOnly)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            // Offline, the chat can't be read either: the question's own mark already says why.
            if let problem = session.askError, session.askSend == .idle {
                Text(problem.words)
                    .font(.appFootnote)
                    .foregroundStyle(problem.isFailure ? Color.toneBad : Color.secondary)
                    .accessibilityIdentifier("pr-ask-read-problem")
            }
            SessionComposer(
                draft: $session.askDraft, isSending: session.isSendingAsk, send: send,
                placeholder: "Ask about this PR", focused: $isWriting
            )
        }
        .composerBar()
    }

    private func send() {
        isWriting = false
        Task { await session.sendAsk() }
    }

    private func waitWhat() {
        isWriting = false
        Task { await session.sendAsk(ChatQuickReply.waitWhat.text) }
    }

    private func retry() {
        Task { await session.retryAsk() }
    }

    /// The failed question's words back in the box, to change before they go again.
    private func editFailed() {
        if case let .failed(question, _) = session.askSend {
            session.redraft(question.question, about: question.anchor)
        } else {
            session.editFailedAsk()
        }
        isWriting = true
    }
}

private extension View {
    @ViewBuilder func askSheetSize() -> some View {
        #if os(iOS)
        presentationDetents([.medium, .large])
        #else
        frame(minWidth: 560, minHeight: 560)
        #endif
    }
}
