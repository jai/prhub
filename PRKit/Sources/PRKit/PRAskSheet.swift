import PRKitCore
import PRKitDesign
import SwiftUI

/// Asking the PR's AI agent, which has the repo at this PR's head and can only read it. A sheet, since it is a real detour:
/// at half height the diff stays in sight. One conversation per PR, kept by the session, so it is here next time.
struct PRAskSheet: View {
    @Bindable var session: PRSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isWriting: Bool

    private var messages: [PRAskChat.Message] {
        session.askMessages
    }

    /// Whether Jai was reading the end of the chat when he last scrolled it: a new message then keeps him there.
    @State private var readsEnd = true
    /// How many questions the chat shows: one more is one he sent, and the sheet goes to the end with it.
    private var asked: Int {
        messages.count(where: \.isJai)
    }

    private var isWorking: Bool {
        session.isAskWorking
    }

    var body: some View {
        NavigationStack {
            ChatView(
                messages: chatMessages,
                emptyText: !isWorking && session.askSend == .idle
                    ? "Ask about this PR. The AI reads the whole repo at this PR's head, and can't change anything."
                    : nil,
                sent: asked, readsEnd: $readsEnd, focus: $isWriting,
                extras: { chatMessage in
                    reviewCard(for: chatMessage)
                    linearCards(for: chatMessage)
                },
                header: { EmptyView() },
                footer: {
                    status
                        .animation(AppMotion.fold, value: isWorking)
                        .animation(AppMotion.swap, value: session.askSend)
                },
                composer: { composer }
            )
            .background(Color.groundPage)
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

    /// The chat as every chat draws it (`ChatView`); a question about a line names the line under it, and his
    /// questions say how far each got. By place: the question drawn on its way becomes the chat's own message with
    /// the same id, so it does not fade out and back in.
    private var chatMessages: [ChatMessage] {
        messages.enumerated().map { index, message in
            ChatMessage(
                id: "ask-\(index)", role: message.isJai ? .mine : .theirs, text: message.text,
                footnote: message.anchor, ticks: session.askTicks(at: index),
                hasExtras: message.draft?.reviewEvent != nil || message.linear?.isEmpty == false
            )
        }
    }

    /// The review an answer drafted, under it: post it, or add it to his drafts to change first.
    @ViewBuilder private func reviewCard(for chatMessage: ChatMessage) -> some View {
        if let index = Int(chatMessage.id.dropFirst("ask-".count)), messages.indices.contains(index),
           let draft = messages[index].draft, let event = draft.reviewEvent
        {
            let message = messages[index]
            PRAskReviewCard(
                draft: draft, event: event, isUsed: session.isUsed(message),
                isNewest: session.pendingAskReview?.id == message.id,
                otherDrafts: session.drafts.count,
                post: { session.postAskReview(message) },
                addToDrafts: { session.addAskReviewToDrafts(message) }
            )
            .padding(.top, Space.sm)
        }
    }

    /// The Linear comments an answer proposed, under it: each posts as Jai once he says yes.
    @ViewBuilder private func linearCards(for chatMessage: ChatMessage) -> some View {
        if let index = Int(chatMessage.id.dropFirst("ask-".count)), messages.indices.contains(index),
           let cards = messages[index].linear, !cards.isEmpty
        {
            let message = messages[index]
            ForEach(Array(cards.enumerated()), id: \.offset) { place, card in
                let key = PRSession.askLinearKey(message, place)
                PRAskLinearCommentCard(
                    card: card, isPosting: session.askLinearPosting.contains(key),
                    problem: session.askLinearProblems[key],
                    isNewest: session.pendingAskLinear.map { $0.0.id == message.id && $0.1 == place } ?? false,
                    post: { Task { await session.postAskLinear(message, index: place) } }
                )
                .padding(.top, Space.sm)
            }
        }
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
            ChatWorkingLine(activity: session.askChat?.activity ?? "Thinking", identifier: "pr-ask-working")
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
            // With no network and the saved chat on screen, the host's offline banner says why it isn't newer.
            if let problem = session.askError, session.askSend == .idle,
               session.model.network.isOnline || session.askChat == nil
            {
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
            session.redraft(question.question, about: question.anchor)
        } else {
            session.editFailedAsk()
        }
        isWriting = true
    }
}

/// A review Ask AI drafted: its verdict, its words and its line comments, not yet on GitHub. Posted, it is Jai's
/// review from his account; added to his drafts, its comments wait in the diff and its words in the review's box.
struct PRAskReviewCard: View {
    let draft: PRAskDraft
    let event: PRReviewEvent
    let isUsed: Bool
    /// The newest answer's: "go" posts it.
    let isNewest: Bool
    /// His own line comments already waiting: they go with it.
    let otherDrafts: Int
    let post: () -> Void
    let addToDrafts: () -> Void

    private var action: PRReviewAction {
        switch event {
        case .approve: .approve
        case .requestChanges: .requestChanges
        case .comment: .comment
        }
    }

    private static let shownComments = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                IconText("Draft review: \(action.title)", icon: action.icon)
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundStyle(action.tone ?? Color.primary)
                Spacer()
                StatusChip(text: isUsed ? "Used" : "Not posted", tint: Color.toneWaiting)
            }
            if !draft.body.isEmpty {
                PRCommentText(draft.body)
            }
            if !draft.comments.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(draft.comments.prefix(Self.shownComments).enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(verbatim: "\(comment.path):\(comment.line)")
                                .font(.app(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(comment.body)
                                .font(.appFootnote)
                                .lineLimit(3)
                        }
                    }
                    if draft.comments.count > Self.shownComments {
                        Text("and \(draft.comments.count - Self.shownComments) more line comments")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !isUsed {
                HStack(spacing: Space.sm) {
                    Button("Post review", systemImage: action.icon.symbol, action: post)
                        .buttonStyle(PRButtonStyle(.primary))
                        .accessibilityIdentifier("pr-ask-review-post")
                    Button("Add to my drafts", systemImage: AppIcon.compose.symbol, action: addToDrafts)
                        .buttonStyle(PRButtonStyle(.secondary))
                        .accessibilityIdentifier("pr-ask-review-drafts")
                }
                Text(footnote)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(PRStyle.inset)
        .prCard()
        .accessibilityIdentifier("pr-ask-review")
    }

    private var footnote: String {
        var words = "Posts as you."
        if otherDrafts > 0 {
            words += otherDrafts == 1 ? " Your 1 other draft comment goes with it." : " Your \(otherDrafts) other draft comments go with it."
        }
        if isNewest {
            words += " Or say \"go\"."
        }
        return words
    }
}

/// A comment Ask AI proposed on one of the PR's Linear tickets: the words exactly as they post, with each mention as the
/// person or agent it reaches. Posted, it is Jai's comment, from his Linear account; a mention of an agent such as
/// Octobot starts its session, shown here with a link to it in Linear.
struct PRAskLinearCommentCard: View {
    let card: PRAskLinearCard
    let isPosting: Bool
    /// Why the yes didn't reach the Worker.
    let problem: String?
    /// The newest answer's only card that can post: "go" posts it.
    let isNewest: Bool
    let post: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                IconText("Comment on \(card.issue)", icon: .conversation)
                    .font(.appSubheadline.weight(.semibold))
                Spacer()
                StatusChip(text: chip.text, tint: chip.tint)
            }
            PRCommentText(card.text)
            if !card.mentions.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(card.mentions, id: \.written) { mention in
                        Group {
                            if let user = mention.user {
                                Text("@\(mention.written) → \(user.name)\(user.agent ? " (agent)" : "")")
                            } else {
                                Text("@\(mention.written) → nobody in Linear").foregroundStyle(Color.toneBad)
                            }
                        }
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("pr-ask-linear-mentions")
            }
            if let session = card.session {
                sessionLine(session)
            }
            if card.state == .posted, let url = card.url {
                Link(destination: url) {
                    IconText("Open the comment in Linear", icon: .openExternally)
                }
                .font(.appFootnote)
                .accessibilityIdentifier("pr-ask-linear-open")
            }
            if let why = card.problem ?? problem ?? card.failure {
                Text(why)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .accessibilityIdentifier("pr-ask-linear-problem")
            }
            if card.canPost {
                Button(action: post) {
                    ZStack {
                        Label(card.state == .failed || problem != nil ? "Retry" : "Post to Linear",
                              systemImage: (card.state == .failed ? AppIcon.refresh : AppIcon.sending).symbol)
                            .opacity(isPosting ? 0 : 1)
                        if isPosting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(PRButtonStyle(.primary))
                .disabled(isPosting)
                .accessibilityIdentifier("pr-ask-linear-post")
                Text(isNewest ? "Posts as you, from your Linear account. Or say \"go\"." : "Posts as you, from your Linear account.")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(PRStyle.inset)
        .prCard()
        .accessibilityIdentifier("pr-ask-linear")
    }

    private var chip: (text: String, tint: Color) {
        switch card.state {
        case .posted: ("Posted", Color.toneGood)
        case .failed: ("Not posted", Color.toneBad)
        case .proposed: (card.problem == nil ? "Not posted" : "Can't post", Color.toneWaiting)
        }
    }

    @ViewBuilder private func sessionLine(_ session: PRAskLinearCard.Session) -> some View {
        let words = "\(session.agent ?? "Agent") session: \(Self.statusWords(session.status))"
        Group {
            if let url = session.url {
                Link(destination: url) { IconText(words, icon: .openExternally) }
            } else {
                IconText(words, icon: .toolCall)
            }
        }
        .font(.appFootnote)
        .accessibilityIdentifier("pr-ask-linear-session")
    }

    static func statusWords(_ status: String) -> String {
        switch status {
        case "pending": "starting"
        case "active": "working"
        case "awaitingInput": "waiting for you"
        case "complete": "done"
        case "error": "failed"
        case "stale": "stopped"
        default: status
        }
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
