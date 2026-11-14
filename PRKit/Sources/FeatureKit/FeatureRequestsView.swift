import PRKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Feature requests ("Feedback"), to an agent that makes the change, tests it and ships a build. Conversation first, as
/// Messages is: the screen lists the conversations, New starts one, and the first message makes it a thread that goes
/// on in place. Where the screen is narrow (a phone, Slide Over) a stack: the list, a conversation pushed over it. Where
/// it is wide (an iPad, the Mac) the list beside the conversation picked. A tab of its own: it brings its navigation.
public struct FeatureRequestsView: View {
    @State private var model: FeatureRequestsModel
    /// The wide layout's open conversation.
    @State private var selection: FeatureRoute?
    /// The narrow layout's conversations, pushed by value onto a stack of its own, so they stay open whatever is
    /// presented over them: More's controller dropped its pushes when a full-screen Files or Photos picker closed
    /// (iOS 27.2).
    @State private var path: [FeatureRoute] = []
    /// The narrow layout's next new conversation: one route until its first message makes it a thread.
    @State private var newRoute = FeatureRoute.new(UUID())
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// More's way back to its list, while the tab is under More (the phone, with more tabs than the bar holds). More's
    /// own bar is hidden then, so the stack's is the only one.
    @State private var more: MoreNavigation?
    #endif

    /// A model the host keeps, so drafts and open chats outlive the screen.
    public init(model: FeatureRequestsModel) {
        _model = State(initialValue: model)
    }

    public init(client: FeatureClient) {
        self.init(model: FeatureRequestsModel(client: client))
    }

    public var body: some View {
        layout
            .task { await model.refresh() }
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if sizeClass == .regular {
            split
        } else {
            stack
                .background(MoreNavigationProbe { more = $0 })
        }
        #else
        split
        #endif
    }

    /// The list, a conversation pushed over it by its row, and New pushing an empty one: the one started and still
    /// empty, else a fresh one.
    private var stack: some View {
        NavigationStack(path: $path) {
            FeatureListView(model: model, selected: nil, isStacked: true) { _ in }
                .inlineNavigationTitle()
                .featureTitle("Feedback")
                .toolbar {
                    #if os(iOS)
                    if let more {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: more.back) {
                                Image(systemName: AppIcon.back.symbol)
                            }
                            .accessibilityLabel("More")
                            .accessibilityIdentifier("feedback-back-to-more")
                        }
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Button("New feedback", systemImage: AppIcon.compose.symbol) {
                            newRoute = model.compose(reusing: newRoute)
                            path = [newRoute]
                        }
                        .accessibilityIdentifier("feedback-new")
                    }
                }
                .navigationDestination(for: FeatureRoute.self) { route in
                    FeatureChatView(model: model, route: route)
                }
        }
    }

    private var split: some View {
        NavigationSplitView {
            FeatureListView(model: model, selected: selection, isStacked: false) { route in
                withAnimation(AppMotion.swap) { selection = route }
            }
            // The app's readable width is the window's; this column is narrower than it.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .navigationTitle("Feedback")
            .sidebarSurface()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New feedback", systemImage: AppIcon.compose.symbol) {
                        withAnimation(AppMotion.fold) { selection = model.compose(reusing: selection) }
                    }
                    .accessibilityIdentifier("feedback-new")
                }
            }
        } detail: {
            NavigationStack {
                ZStack {
                    if let selection {
                        FeatureChatView(model: model, route: selection)
                            .id(selection)
                            .transition(.opacity)
                    } else {
                        ContentUnavailableView(
                            "No feedback open", systemImage: AppIcon.conversation.symbol,
                            description: Text("Pick a conversation, or start new feedback.")
                        )
                        .transition(.opacity)
                    }
                }
                .animation(AppMotion.swap, value: selection)
            }
            // Measured again in this column, so the conversation centres in what the column has.
            .readableContentWidth()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

extension View {
    /// A Feedback screen's title, on the phone in the bar's principal place in the app's own type.
    @ViewBuilder func featureTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.appSubheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
        #else
        navigationTitle(title)
        #endif
    }
}

/// The conversations, newest first; on a wide screen the open one is marked, and a new one not sent yet sits on top.
private struct FeatureListView: View {
    let model: FeatureRequestsModel
    let selected: FeatureRoute?
    /// Pushed rows carry a chevron; rows beside their conversation are marked instead.
    let isStacked: Bool
    let open: (FeatureRoute) -> Void

    private var unsent: FeatureRoute? {
        guard let selected, case .new = selected, model.thread(for: selected) == nil else {
            return nil
        }
        return selected
    }

    private var selectedThread: String? { selected.flatMap(model.thread(for:)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xs) {
                if !model.list.builderOnline {
                    BuilderNote()
                        .padding(.bottom, Space.xs)
                }
                if let unsent {
                    row(route: unsent, title: "New feedback", date: nil, isSelected: true)
                        .transition(.fold)
                }
                if model.list.threads.isEmpty, unsent == nil {
                    Text(model.list.notice ?? FeatureList.agentNotice)
                        .font(.appFootnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.lg)
                        .accessibilityIdentifier("feedback-empty")
                }
                ForEach(model.list.threads) { thread in
                    row(
                        route: .thread(thread.id), title: thread.title,
                        date: try? Date(thread.createdAt, strategy: .iso8601), isSelected: selectedThread == thread.id
                    )
                    .transition(.fold)
                }
                if let error = model.error {
                    Text(error)
                        .font(.appFootnote)
                        .foregroundStyle(Color.toneBad)
                        .padding(.horizontal, Space.lg)
                }
            }
            .padding(.vertical, Space.sm)
            .animation(AppMotion.fold, value: model.list)
            .animation(AppMotion.fold, value: unsent)
        }
        .background(HomePalette.screenBackground)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func row(route: FeatureRoute, title: String, date: Date?, isSelected: Bool) -> some View {
        if isStacked {
            NavigationLink(value: route) {
                rowLabel(title: title, date: date, isSelected: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feedback-thread")
        } else {
            Button { open(route) } label: { rowLabel(title: title, date: date, isSelected: isSelected) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feedback-thread")
        }
    }

    private func rowLabel(title: String, date: Date?, isSelected: Bool) -> some View {
        HStack(spacing: Space.md) {
            Text(title)
                .font(.appSubheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let date {
                Text(ThreadTimeFormat().age(date, now: .now))
                    .font(.appCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if isStacked {
                Image(systemName: AppIcon.drillIn.symbol)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(HomePalette.cardBackground)
        .selected(isSelected && !isStacked)
        .contentShape(.rect)
    }
}

/// Without the builder Mac polling, feedback waits in the queue. It says so, so a silent chat isn't a mystery.
private struct BuilderNote: View {
    var body: some View {
        Label {
            Text("The builder Mac is offline. Feedback waits until it is back.")
        } icon: {
            Image(systemName: AppIcon.paused.symbol)
        }
        .font(.appCaption)
        .foregroundStyle(Color.toneWaiting)
        .padding(.horizontal, Space.lg)
        .accessibilityIdentifier("feedback-builder-offline")
    }
}

/// One conversation: what Jai said and what the agent did with it, with a box to say more. A new one is empty, with
/// the box ready; its first message makes the thread, and the conversation goes on here.
struct FeatureChatView: View {
    @Bindable var model: FeatureRequestsModel
    let route: FeatureRoute
    @FocusState private var isWriting: Bool

    private var box: String { route.box }
    private var thread: String? { model.thread(for: route) }
    private var chat: FeatureChat? { thread.flatMap { model.chats[$0] } }
    private var isNew: Bool { thread == nil && !model.isSending(box) }

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
        ChatView(
            messages: messages.map {
                ChatMessage(
                    id: $0.id, role: $0.isJai ? .mine : .theirs,
                    text: ScreenshotLine.bubbleText($0.text, screenshots: screenshots($0))
                )
            },
            sends: messages.count(where: \.isJai), readsEnd: $readsEnd, focus: $isWriting,
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
        .background(HomePalette.screenBackground)
        .inlineNavigationTitle()
        .featureTitle(model.title(for: route) ?? "New feedback")
        .task(id: thread) {
            if thread == nil {
                isWriting = true
            }
        }
        .task(id: FollowKey(thread: thread, isLive: chat?.isWorking == true || model.isSending(box))) {
            await model.follow(route)
        }
        .task { await model.seedScreenshot(in: box) }
    }

    private struct FollowKey: Hashable {
        let thread: String?
        let isLive: Bool
    }

    @ViewBuilder private var status: some View {
        if chat?.isWorking == true || model.isSending(box) {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(chat?.builderOnline == false ? "Waiting for the builder Mac" : chat?.activity ?? "Thinking")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PRStyle.inset)
            .accessibilityIdentifier("feedback-working")
        } else if let problem = chat?.problem {
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
                draft: model.binding(for: box), isSending: model.isSending(box), send: send,
                placeholder: thread == nil ? "What should change?" : "Reply", focused: $isWriting,
                attachments: model.attachments(for: box)
            )
        }
        .animation(AppMotion.fold, value: model.error)
        .composerBar()
    }

    private func send() {
        isWriting = false
        Task { await model.send(route) }
    }
}

extension FeatureList {
    /// What sending does when the Worker gives no notice: the owner's coding agent.
    static let agentNotice = "Say what to change in the app. An agent makes the change, tests it and ships a build."
}
