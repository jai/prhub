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
        guard let pending = session.askPending, !sent.contains(where: { $0.isJai && $0.text == pending }) else {
            return sent
        }
        return sent + [PRAskChat.Message(id: "pending", role: "you", text: pending, anchor: nil)]
    }
    private var isWorking: Bool { session.isSendingAsk || session.askChat?.isWorking == true }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ChatScroll {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if messages.isEmpty, !isWorking {
                            Text("Ask about this PR. The AI reads the whole repo at this PR's head, and can't change anything.")
                                .font(.appFootnote)
                                .foregroundStyle(.secondary)
                                .padding(PRStyle.inset)
                        }
                        ForEach(messages) { message($0).transition(.fold) }
                        status.id(Self.end)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .animation(AppMotion.fold, value: messages)
                    .animation(AppMotion.fold, value: isWorking)
                }
                .dismissesKeyboard($isWriting)
                .onChange(of: messages.count) {
                    withAnimation(AppMotion.fold) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .background(HomePalette.screenBackground)
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
        .task(id: session.askChat?.isWorking == true || session.isSendingAsk) { await session.followAsk() }
        .askSheetSize()
        // Only when there is nothing yet: words from a line's box are already on their way.
        .onAppear { isWriting = messages.isEmpty && session.askDraft.isEmpty && session.askPending == nil }
    }

    private static let end = "end"

    /// A message as every chat draws it; a question about a line names the line under it.
    private func message(_ message: PRAskChat.Message) -> some View {
        SessionBubble(title: nil, text: message.text, date: nil, isMine: message.isJai, footnote: message.anchor)
    }

    @ViewBuilder private var status: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.askChat?.activity ?? "Thinking")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PRStyle.inset)
            .accessibilityIdentifier("pr-ask-working")
        } else if let problem = session.askChat?.problem {
            Text(problem)
                .font(.appFootnote)
                .foregroundStyle(Color("ToneBad"))
                .padding(.horizontal, PRStyle.inset)
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
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = session.askAnchor {
                HStack(spacing: 8) {
                    Text(verbatim: "\(anchor.path):\(anchor.line)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Ask about the whole PR", systemImage: "xmark") { session.askAnchor = nil }
                        .labelStyle(.iconOnly)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            if let error = session.askError {
                Text(error)
                    .font(.appFootnote)
                    .foregroundStyle(Color("ToneBad"))
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
