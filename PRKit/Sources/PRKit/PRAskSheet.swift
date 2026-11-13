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
    /// What the end of the chat shows: when it changes, the sheet scrolls to it.
    private var tail: [String] {
        [
            String(messages.count), messages.last?.text ?? "", String(isWorking), String(describing: session.askSend),
            String(isWriting),
        ]
    }
    /// The agent at work on a question it has. A question still on its way says so instead.
    private var isWorking: Bool { session.askSend == .idle && session.askChat?.isWorking == true }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ChatScroll {
                    LazyVStack(alignment: .leading, spacing: Space.sm) {
                        if messages.isEmpty, !isWorking, session.askSend == .idle {
                            Text("Ask about this PR. The AI reads the whole repo at this PR's head, and can't change anything.")
                                .font(.appFootnote)
                                .foregroundStyle(.secondary)
                                .padding(PRStyle.inset)
                        }
                        // By place: the question drawn on its way becomes the chat's own message, with no fold out and
                        // back in, which left the sheet scrolled past it.
                        ForEach(Array(messages.enumerated()), id: \.offset) {
                            message($0.element).transition(.fold)
                        }
                        status.id(Self.end)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .animation(AppMotion.fold, value: messages)
                    .animation(AppMotion.fold, value: isWorking)
                    .animation(AppMotion.swap, value: session.askSend)
                }
                .dismissesKeyboard($isWriting)
                // The foot follows anything that changes the end: a message, its words, the agent's work, the send's
                // state, and the keyboard going as the question is sent.
                .onChange(of: tail) {
                    withAnimation(AppMotion.fold) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
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
        .askSheetSize()
        // Only when there is nothing yet: words from a line's box are already on their way.
        .onAppear { isWriting = messages.isEmpty && session.askDraft.isEmpty && session.askSend == .idle }
    }

    private static let end = "end"

    /// A message as every chat draws it; a question about a line names the line under it.
    private func message(_ message: PRAskChat.Message) -> some View {
        SessionBubble(title: nil, text: message.text, date: nil, isMine: message.isJai, footnote: message.anchor)
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
            if session.askChat?.messages.last?.isJai == true, session.askChat?.unsentQuestion == nil {
                quietMark("Sent", icon: .done)
                    .accessibilityIdentifier("pr-ask-sent")
            }
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
                    Button("Ask about the whole PR", systemImage: AppIcon.close.symbol) { session.askAnchor = nil }
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

    private func retry() {
        Task { await session.retryAsk() }
    }

    /// The failed question's words back in the box, to change before they go again.
    private func editFailed() {
        if case let .failed(question, _) = session.askSend {
            session.askDraft = question.question
            session.askAnchor = question.anchor ?? session.askAnchor
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
