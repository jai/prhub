import PRKit
import SwiftUI

/// One conversation: what Jai said and what the agent did with it, with a box to say more. A new one is empty, with
/// the box ready; its first message makes the thread, and the conversation goes on here.
struct FeatureChatView: View {
    @Bindable var model: FeatureRequestsModel
    let route: FeatureRoute
    let conversation: ((FeatureConversation) -> AnyView?)?
    @FocusState private var isWriting: Bool

    private var box: String { route.box }
    private var thread: String? { model.thread(for: route) }
    private var chat: FeatureChat? { thread.flatMap { model.chats[$0] } }
    private var isNew: Bool { thread == nil && !model.isSending(box) }
    /// Legacy messages stay visible until delivered; the host also decides whether its thread is ready to draw.
    var hostedConversation: AnyView? {
        guard let conversation, let chat, let thread = chat.thread,
              !model.isSending(box), !chat.hasUndeliveredMessages
        else {
            return nil
        }
        return conversation(FeatureConversation(
            thread: thread, draft: model.binding(for: box), attachments: model.attachments(for: box)
        ))
    }

    /// Once the first message created the feedback chat, the host's coding thread receives every follow-up.
    var awaitsAgentThread: Bool { conversation != nil && thread != nil }

    private var messages: [PRAskChat.Message] {
        let sent = chat?.messages ?? []
        guard let pending = model.pending[box], !sent.contains(where: { $0.isJai && $0.text == pending.text })
        else {
            return sent
        }
        return sent + [PRAskChat.Message(id: Self.pendingID, role: "you", text: pending.text, anchor: nil)]
    }

    private static let pendingID = "pending"

    private func screenshots(_ message: PRAskChat.Message) -> Int {
        message.id == Self.pendingID ? model.pending[box]?.screenshots ?? 0 : chat?.screenshots[message.id] ?? 0
    }

    /// Whether Jai was reading the end of the chat when he last scrolled it: a new message then keeps him there.
    @State private var readsEnd = true

    var body: some View {
        let hosted = hostedConversation
        Group {
            if let hosted {
                hosted
            } else {
                feedbackConversation
                    .inlineNavigationTitle()
                    .featureTitle(model.title(for: route) ?? "New feedback")
            }
        }
        .background(HomePalette.screenBackground)
        .task(id: thread) {
            if thread == nil {
                isWriting = true
            }
        }
        .task(id: FollowKey(
            thread: thread, isLive: chat?.isWorking == true || model.isSending(box), isHosted: hosted != nil
        )) {
            if hosted == nil {
                await model.follow(route, mode: conversation == nil ? .whileWorking : .untilHandoff)
            }
        }
        .task { await model.seedScreenshot(in: box) }
    }

    private var feedbackConversation: some View {
        ChatView(
            messages: messages.map {
                ChatMessage(
                    id: $0.id, role: $0.isJai ? .mine : .theirs,
                    text: ScreenshotLine.bubbleText($0.text, screenshots: screenshots($0))
                )
            },
            sent: messages.count(where: \.isJai), readsEnd: $readsEnd, focus: $isWriting,
            extras: { _ in EmptyView() },
            header: {
                if chat?.builderOnline == false || (isNew && !model.list.builderOnline) {
                    BuilderNote()
                }
                if messages.isEmpty {
                    Text(model.list.notice ?? FeatureList.agentNotice)
                        .font(.appFootnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Space.lg)
                        .transition(.opacity)
                        .accessibilityIdentifier("feedback-new-hint")
                }
            },
            footer: {
                status
                    .animation(AppMotion.fold, value: chat?.isWorking)
            },
            composer: { composer }
        )
    }

    private struct FollowKey: Hashable {
        let thread: String?
        let isLive: Bool
        let isHosted: Bool
    }

    @ViewBuilder private var status: some View {
        if showsWorking {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(activity)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PRStyle.inset)
            .accessibilityIdentifier("feedback-working")
        } else if let problem = handoffProblem {
            Text(problem)
                .font(.appFootnote)
                .foregroundStyle(Color.toneBad)
                .padding(.horizontal, PRStyle.inset)
        } else if let cents = chat?.costCents, !messages.isEmpty {
            Text("\((Double(cents) / 100).formatted(.currency(code: "USD"))) so far, of $10")
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PRStyle.inset)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var showsWorking: Bool {
        if awaitsAgentThread {
            return handoffProblem == nil
        }
        return chat?.isWorking == true || model.isSending(box)
    }

    var handoffProblem: String? {
        if let problem = chat?.problem {
            return problem
        }
        if awaitsAgentThread, chat?.delivery.values.contains(.failed) == true {
            return "An earlier message did not reach the agent. Start new feedback to continue."
        }
        return nil
    }

    private var activity: String {
        if awaitsAgentThread {
            return chat?.thread == nil ? "Starting the agent…" : "Waiting for the agent thread"
        }
        return chat?.builderOnline == false ? "Waiting for the builder Mac" : chat?.activity ?? "Thinking"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let error = model.error {
                Text(error)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .readableBarWidth()
                    .transition(.fold)
            }
            SessionComposer(
                draft: model.binding(for: box), isSending: model.isSending(box) || awaitsAgentThread, send: send,
                placeholder: thread == nil ? "What should change?" : "Reply", focused: $isWriting,
                attachments: model.attachments(for: box)
            )
        }
        .animation(AppMotion.fold, value: model.error)
        .composerBar()
    }

    private func send() {
        guard !awaitsAgentThread else {
            return
        }
        isWriting = false
        Task {
            if conversation != nil {
                await model.sendFirstMessage(route)
            } else {
                await model.send(route)
            }
        }
    }
}

extension FeatureList {
    /// What sending does when the Worker gives no notice: the owner's coding agent.
    static let agentNotice = "Say what to change in the app. An agent makes the change, tests it and ships a build."
}
