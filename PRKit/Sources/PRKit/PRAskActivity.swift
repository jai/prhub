import PRKitCore
import PRKitDesign
import SwiftUI

/// A PR's Ask AI chat still going, or answered and unread, after its sheet went away (Jai's feedback: once the sheet was
/// dismissed nothing said a chat was live). One per PR; several can go at once. Kept while the app runs.
struct PRAskActivity: Equatable {
    enum Phase: Equatable {
        /// The agent at work, in its own words ("Reading the repo").
        case working(String)
        /// It answered while the sheet was away, and the answer has not been read.
        case answered
    }

    let ref: PullRequestRef
    var phase: Phase

    var words: String {
        switch phase {
        case let .working(activity): activity.hasSuffix("…") ? activity : activity + "…"
        case .answered: "Answer ready"
        }
    }

    var isWorking: Bool {
        if case .working = phase {
            true
        } else {
            false
        }
    }
}

extension PRsModel {
    /// The sheet went away with the agent still at work: the model keeps reading the chat, as the sheet did, until it
    /// answers, and the answer then waits as unread. Each PR's chat is read on its own.
    func followAskAway(_ ref: PullRequestRef) {
        askAwayFollows[ref]?.cancel()
        askAwayFollows[ref] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                do {
                    let chat = try await askChat(ref)
                    failures = 0
                    guard !Task.isCancelled else {
                        return
                    }
                    let phase = chat.isWorking ? PRAskActivity.Phase.working(chat.activity ?? "Thinking") : .answered
                    let next = PRAskActivity(ref: ref, phase: phase)
                    // Read every 2 s: the PR list is drawn again only when the line says something else.
                    if askActivities[ref] != next {
                        withAnimation(AppMotion.swap) { askActivities[ref] = next }
                    }
                    if !chat.isWorking {
                        askAwayFollows[ref] = nil
                        return
                    }
                } catch {
                    failures += 1
                }
                try? await sleep(PRSession.askPollWait(afterFailures: failures))
            }
        }
    }

    /// The sheet shows this PR's chat again: it reads the chat itself, and an answer there is read.
    func askSheetOpened(_ ref: PullRequestRef) {
        askAwayFollows.removeValue(forKey: ref)?.cancel()
        if askActivities[ref] != nil {
            withAnimation(AppMotion.fold) { askActivities[ref] = nil }
        }
    }

    /// What the sheet last read, while it shows: working, or nothing to say once it has answered in sight.
    func askSheetRead(_ ref: PullRequestRef, chat: PRAskChat?, isOnItsWay: Bool) {
        let isWorking = chat?.isWorking == true || isOnItsWay
        let next = isWorking ? PRAskActivity(ref: ref, phase: .working(chat?.activity ?? "Thinking")) : nil
        if askActivities[ref] != next {
            withAnimation(AppMotion.swap) { askActivities[ref] = next }
        }
    }
}

public extension PRKitController {
    /// Whether the PR on top of the PRs tab has a chat working or answered and unread: the host's bar shows it there,
    /// and nowhere else.
    var hasAskActivityOnScreen: Bool {
        askActivityOnScreen != nil
    }

    internal var askActivityOnScreen: PRAskActivity? {
        navigation.routes.last.flatMap { model.askActivities[$0.session.ref] }
    }

    /// Opens the chat of the PR on top.
    internal func openAskOnScreen() {
        navigation.routes.last?.session.openAsk()
    }

    #if DEBUG
        /// A UI test's live chat on `ref`: working, or answered and unread.
        func showAskActivity(on ref: PullRequestRef, answered: Bool) {
            model.askActivities[ref] = PRAskActivity(ref: ref, phase: answered ? .answered : .working("Reading the repo"))
        }
    #endif
}

/// The chat of the PR on screen in one line: a spinner and what the agent is doing, or a green tick and Answer ready.
/// The tab bar's bottom accessory holds it, on a PR's pages only; a tap opens the chat.
public struct PRAskStatusBar: View {
    let kit: PRKitController
    #if os(iOS)
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif

    public init(_ kit: PRKitController) {
        self.kit = kit
    }

    private var isInline: Bool {
        #if os(iOS)
            placement == .inline
        #else
            false
        #endif
    }

    public var body: some View {
        if let activity = kit.askActivityOnScreen {
            Button { kit.openAskOnScreen() } label: {
                HStack(spacing: Space.sm) {
                    PRAskStatusMark(phase: activity.phase)
                    Text(activity.words)
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer(minLength: Space.xs)
                    if !isInline {
                        Text("Ask AI")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Space.lg)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .animation(AppMotion.swap, value: activity.phase)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ask AI: \(activity.words)")
            .accessibilityHint("Opens the chat")
            .accessibilityIdentifier("pr-ask-status-bar")
        }
    }
}

/// The spinner while the agent works; a green tick once it has answered.
struct PRAskStatusMark: View {
    let phase: PRAskActivity.Phase

    var body: some View {
        Group {
            switch phase {
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .answered:
                Image(AppIcon.done)
                    .foregroundStyle(Color.toneGood)
                    .fontWeight(.semibold)
            }
        }
        .transition(.opacity)
    }
}

/// The chats a list's rows show, by PR, and the way to open one: set by the PRs tab (`PRsView`), empty elsewhere.
struct PRAskLines {
    var activities: [PullRequestRef: PRAskActivity] = [:]
    var open: (PullRequestRef) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var askLines = PRAskLines()
}

/// A PR's live chat on its row's rail, as the ticket line is: the bar's mark and words, then Ask AI. The whole line
/// opens the PR with its chat, 44 pt tall at least.
struct PRAskLine: View {
    let activity: PRAskActivity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.sm) {
                PRAskStatusMark(phase: activity.phase)
                    .frame(width: PrListGrid.state)
                Text(activity.words)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: Space.xs)
                Text("Ask AI")
                    .font(.appCaption)
                    .foregroundStyle(Color.secondary)
            }
            .frame(minHeight: PRStyle.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(AppMotion.swap, value: activity.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask AI: \(activity.words)")
        .accessibilityHint("Opens the chat")
        .accessibilityIdentifier("pr-row-ask-\(activity.ref.repo)#\(activity.ref.number)")
    }
}
