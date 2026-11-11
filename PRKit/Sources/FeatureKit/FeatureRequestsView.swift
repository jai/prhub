import PRKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where `FeatureRequestsView` puts its conversations.
public enum FeatureNavigation: Sendable {
    /// A tab of its own: it brings its navigation, a stack where the screen is narrow and a split view where it is wide.
    case own
    /// Pushed onto the host's `NavigationStack`: no stack of its own, and each conversation pushes onto the host's.
    case host
}

/// A chat channel's conversations, each with an agent on the owner's Mac (Feedback: an agent that makes the change,
/// tests it and ships a build). Conversation first, as Messages is: the screen lists the conversations, New starts
/// one, and the first message makes it a thread that goes on in place. `FeatureNavigation.own`: where the screen is
/// narrow (a phone, Slide Over) a stack, the list with a conversation pushed over it, and where it is wide (an iPad, the
/// Mac) the list beside the conversation picked. `.host`: the list in the host's stack, a conversation pushed over it.
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
    /// `.host`'s conversation pushed onto the host's stack.
    @State private var pushed: FeatureRoute?
    private let navigation: FeatureNavigation
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// More's way back to its list, while the tab is under More (the phone, with more tabs than the bar holds). More's
    /// own bar is hidden then, so the stack's is the only one.
    @State private var more: MoreNavigation?
    #endif

    /// A model the host keeps, so drafts and open chats outlive the screen.
    public init(model: FeatureRequestsModel, navigation: FeatureNavigation = .own) {
        _model = State(initialValue: model)
        self.navigation = navigation
    }

    public init(client: FeatureClient, wording: FeatureWording = .feedback, navigation: FeatureNavigation = .own) {
        self.init(model: FeatureRequestsModel(client: client, wording: wording), navigation: navigation)
    }

    public var body: some View {
        layout
            .task { await model.refresh() }
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if navigation == .host {
            hosted
        } else if sizeClass == .regular {
            split
        } else {
            stack
                .background(MoreNavigationProbe { more = $0 })
        }
        #else
        if navigation == .host {
            hosted
        } else {
            split
        }
        #endif
    }

    /// The list in the host's stack; a row or New pushes its conversation onto it.
    private var hosted: some View {
        FeatureListView(model: model, selected: nil, isStacked: true, pushesByValue: false) { pushed = $0 }
            .inlineNavigationTitle()
            .featureTitle(model.wording.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.wording.newChat, systemImage: AppIcon.compose.symbol) {
                        newRoute = model.compose(reusing: newRoute)
                        pushed = newRoute
                    }
                    .accessibilityIdentifier("feedback-new")
                }
            }
            .navigationDestination(item: $pushed) { route in
                FeatureChatView(model: model, route: route)
            }
    }

    /// The list, a conversation pushed over it by its row, and New pushing an empty one: the one started and still
    /// empty, else a fresh one.
    private var stack: some View {
        NavigationStack(path: $path) {
            FeatureListView(model: model, selected: nil, isStacked: true, pushesByValue: true) { _ in }
                .inlineNavigationTitle()
                .featureTitle(model.wording.title)
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
                        Button(model.wording.newChat, systemImage: AppIcon.compose.symbol) {
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
            FeatureListView(model: model, selected: selection, isStacked: false, pushesByValue: false) { route in
                withAnimation(AppMotion.swap) { selection = route }
            }
            // The app's readable width is the window's; this column is narrower than it.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .navigationTitle(model.wording.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.wording.newChat, systemImage: AppIcon.compose.symbol) {
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
                            model.wording.noneOpen, systemImage: AppIcon.conversation.symbol,
                            description: Text(model.wording.noneOpenHint)
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
    /// Pushed by value onto the view's own stack; else `open` takes the row.
    let pushesByValue: Bool
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
                    BuilderNote(whileOffline: model.wording.whileOffline)
                        .padding(.bottom, Space.xs)
                }
                if let unsent {
                    row(route: unsent, title: model.wording.newChat, date: nil, isSelected: true)
                        .transition(.fold)
                }
                if model.list.threads.isEmpty, unsent == nil {
                    Text(model.wording.emptyPrompt)
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
        if pushesByValue {
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

/// Without the builder Mac polling, a message waits in the queue. It says so, so a silent chat isn't a mystery.
private struct BuilderNote: View {
    let whileOffline: String

    var body: some View {
        Label {
            Text("The builder Mac is offline. \(whileOffline)")
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

    var body: some View {
        ScrollViewReader { proxy in
            ChatScroll {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    if chat?.builderOnline == false || (isNew && !model.list.builderOnline) {
                        BuilderNote(whileOffline: model.wording.whileOffline)
                    }
                    if messages.isEmpty {
                        Text(model.wording.emptyPrompt)
                            .font(.appFootnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Space.lg)
                            .transition(.opacity)
                            .accessibilityIdentifier("feedback-new-hint")
                    }
                    ForEach(messages) { message($0).transition(.fold) }
                    status.id(Self.end)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .animation(AppMotion.fold, value: messages)
                .animation(AppMotion.fold, value: chat?.isWorking)
            }
            .dismissesKeyboard($isWriting)
            .onChange(of: messages.count) {
                withAnimation(AppMotion.fold) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            #if os(iOS)
            // The keyboard covers the end of the chat: once it is up, the last message sits over the box, as Messages
            // has it.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                withAnimation(AppMotion.fold) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            #endif
        }
        .background(HomePalette.screenBackground)
        .safeAreaBar(edge: .bottom) { composer }
        .inlineNavigationTitle()
        .featureTitle(model.title(for: route) ?? model.wording.newChat)
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

    private static let end = "end"

    /// A message as every chat draws it.
    private func message(_ message: PRAskChat.Message) -> some View {
        SessionBubble(
            title: nil, text: ScreenshotLine.bubbleText(message.text, screenshots: screenshots(message)), date: nil,
            isMine: message.isJai
        )
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
                placeholder: thread == nil ? model.wording.placeholder : "Reply", focused: $isWriting,
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
