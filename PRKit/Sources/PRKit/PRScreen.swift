import PRKitCore
import PRKitDesign
import QuartzCore
import SwiftUI

/// Times one open of the diff: from the tap to the first screen tick after rows are laid out. That tick means the frame
/// is committed and the main thread is free.
@MainActor
@Observable
final class DiffOpenTimer {
    private(set) var milliseconds: Double?
    private var startedAt: CFTimeInterval
    private var link: CADisplayLink?

    init(startedAt: CFTimeInterval) {
        self.startedAt = startedAt
    }

    func restart() {
        startedAt = CACurrentMediaTime()
        milliseconds = nil
    }

    func contentLaidOut() {
        guard link == nil, milliseconds == nil else {
            return
        }
        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        #else
        // The Mac has no display link here; the next turn of the run loop is after the frame is drawn.
        DispatchQueue.main.async { self.milliseconds = (CACurrentMediaTime() - self.startedAt) * 1000 }
        #endif
    }

    @objc private func tick() {
        milliseconds = (CACurrentMediaTime() - startedAt) * 1000
        link?.invalidate()
        link = nil
    }
}

/// One PR: its description and conversation, with a way into its diff (`PRDiffScreen`), which is pushed over it. All of
/// it comes from the session. Anything below that keeps state of its own, such as a half-typed comment, goes when the
/// session does, through the `.id`.
struct PRScreen: View {
    @Bindable var session: PRSession
    @Environment(\.pullRequestOpener) private var opener

    var body: some View {
        PRLoadedContent(session: session) { content in
            PRDescriptionView(session: session, detail: content.detail) { opener?.showDiff(of: session) }
        }
        .id(ObjectIdentifier(session))
        .navigationTitle(session.label)
        .inlineNavigationTitle()
        .macBackButton { opener?.stack.backFromPullRequest() }
        .pullRequestActions(session, showsAsk: !session.isDiffOnScreen)
        .onAppear { session.hasShownDescription = true }
        .task(id: ObjectIdentifier(session)) { await session.loadIfNeeded() }
    }
}

/// A PR's diff, pushed over its PR: Back is the PR. The bars leave as the code is read, and the panel of files and key
/// lines is over it on a phone and beside it where there is room.
struct PRDiffScreen: View {
    @Bindable var session: PRSession
    @Environment(\.pullRequestOpener) private var opener

    var body: some View {
        PRLoadedContent(session: session) { content in
            switch content.diff {
            case let .document(document, rows):
                PRDiffPage(session: session, document: document, rows: rows) { opener?.stack.back() }
            case .tooLarge:
                ContentUnavailableView(
                    "Diff too large", systemImage: "doc.text.magnifyingglass",
                    description: Text("GitHub won't supply a diff this big. Use Open in GitHub.")
                )
            }
        }
        .id(ObjectIdentifier(session))
        .navigationTitle("Files changed")
        .navigationSubtitle(session.label)
        .inlineNavigationTitle()
        .macBackButton { opener?.stack.back() }
        .pullRequestActions(session, showsAsk: session.isDiffOnScreen)
        .phoneBarsHidden(session.barsHidden)
        .animation(AppMotion.fold, value: session.barsHidden)
        .onAppear { session.diffAppeared() }
        .onDisappear {
            PRPlatform.endEditing()
            session.diffDisappeared()
        }
        .onChange(of: session.timer.milliseconds) { report() }
        .task(id: ObjectIdentifier(session)) { await session.loadIfNeeded() }
    }

    private func report() {
        guard case let .document(document, _) = session.content?.diff,
              let milliseconds = session.timer.milliseconds else {
            return
        }
        #if DEBUG
        print("PRBENCH \(session.summary(document))")
        #endif
        session.report(document: document, milliseconds: milliseconds)
    }
}

/// A PR's screen while it is read from GitHub, when that fails, and once it is there.
private struct PRLoadedContent<Content: View>: View {
    let session: PRSession
    @ViewBuilder let content: (PRContent) -> Content

    var body: some View {
        switch session.state {
        case .reading:
            Text("Reading this PR from GitHub")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(reason):
            ContentUnavailableView {
                Label("Couldn't read this PR", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("Try again") { Task { await session.retry() } }
                    .buttonStyle(PRButtonStyle(.secondary))
            }
        case let .ready(content):
            self.content(content)
                .transition(.opacity)
        }
    }
}

private extension View {
    /// Ask AI and Open in GitHub, on the PR and on its diff. Only the screen on top shows the Ask sheet: the PR stays
    /// under its diff, and two sheets on one flag would fight.
    func pullRequestActions(_ session: PRSession, showsAsk: Bool) -> some View {
        sheet(isPresented: Binding(
            get: { showsAsk && session.isShowingAsk }, set: { session.isShowingAsk = $0 }
        )) { PRAskSheet(session: session) }
        .toolbar {
            if session.content != nil, session.offersAsk {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ask AI", systemImage: "bubble.left.and.text.bubble.right") { session.openAsk() }
                        .accessibilityIdentifier("pr-ask")
                }
            }
            if let url = session.content.flatMap({ URL(string: $0.detail.url) }) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in GitHub", systemImage: AppIcon.openInGitHub.symbol) { PRPlatform.openExternally(url) }
                        .accessibilityIdentifier("open-in-github")
                        .accessibilityValue(url.absoluteString)
                }
            }
        }
    }

    /// The system's Back and Forward on the Mac walk a history, which is not where a PR came from. This is one Back, which
    /// does what the stack says.
    @ViewBuilder func macBackButton(_ back: @escaping () -> Void) -> some View {
        #if os(macOS)
        modifier(MacBackButton(back: back))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacBackButton: ViewModifier {
    let back: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: back)
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
    }
}
#endif
