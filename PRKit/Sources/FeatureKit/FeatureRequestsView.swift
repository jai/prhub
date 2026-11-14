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
    private let conversation: ((FeatureAgentThread) -> AnyView)?
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
        conversation = nil
    }

    /// Keeps Feedback's list and first-message flow, then shows the host's coding-thread conversation once the
    /// runner names it. The host owns that conversation's delivery statuses, reply queue and Send now controls.
    public init<Conversation: View>(
        model: FeatureRequestsModel, @ViewBuilder conversation: @escaping (FeatureAgentThread) -> Conversation
    ) {
        _model = State(initialValue: model)
        self.conversation = { AnyView(conversation($0)) }
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
                    FeatureChatView(model: model, route: route, conversation: conversation)
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
                        FeatureChatView(model: model, route: selection, conversation: conversation)
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
struct BuilderNote: View {
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

