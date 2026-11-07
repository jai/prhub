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

enum PRPage: String, CaseIterable, Identifiable {
    case description = "Description"
    case diff = "Diff"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .description: "doc.text"
        case .diff: "plus.forwardslash.minus"
        }
    }
}

/// One PR: its description and conversation, and its diff with the review threads in place. All of it comes from the
/// session, the page on show included. Anything below that keeps state of its own, such as a half-typed comment, goes
/// when the session does, through the `.id`.
struct PRScreen: View {
    @Bindable var session: PRSession
    var body: some View {
        content
            .id(ObjectIdentifier(session))
            .animation(AppMotion.swap, value: session.page)
            .inlineNavigationTitle()
            .macBackButton()
            .sheet(isPresented: $session.isShowingAsk) { PRAskSheet(session: session) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Page", selection: $session.page) {
                        ForEach(PRPage.allCases) { page in
                            Image(systemName: page.symbol)
                                .accessibilityLabel(page.rawValue)
                                .tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                }
                if session.content != nil, session.offersAsk {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Ask AI", systemImage: "bubble.left.and.text.bubble.right") { session.openAsk() }
                            .accessibilityIdentifier("pr-ask")
                    }
                }
                if let url = session.content.flatMap({ URL(string: $0.detail.url) }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in GitHub", systemImage: "safari") { PRPlatform.openExternally(url) }
                            .accessibilityIdentifier("open-in-github")
                            .accessibilityValue(url.absoluteString)
                    }
                }
            }
            .phoneBarsHidden(session.page == .diff && session.barsHidden)
            .animation(AppMotion.fold, value: session.barsHidden)
            .onChange(of: session.page) {
                PRPlatform.endEditing()
                session.barsHidden = false
            }
            // Back from a pushed screen, or the app: the bars are there to leave by.
            .onAppear { session.barsHidden = false }
            .onChange(of: session.timer.milliseconds) { report() }
            .task(id: ObjectIdentifier(session)) { await session.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .reading:
            message("Reading this PR from GitHub")
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
            ZStack {
                shown(.description) { PRDescriptionView(session: session, detail: content.detail) }
                if session.hasOpenedDiff {
                    shown(.diff) { diff(content) }
                }
            }
        }
    }

    private func shown(_ page: PRPage, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(session.page == page ? 1 : 0)
            .allowsHitTesting(session.page == page)
            .accessibilityHidden(session.page != page)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func diff(_ content: PRContent) -> some View {
        switch content.diff {
        case let .document(document, rows):
            PRDiffPage(session: session, document: document, rows: rows)
        case .tooLarge:
            ContentUnavailableView(
                "Diff too large", systemImage: "doc.text.magnifyingglass",
                description: Text("GitHub won't supply a diff this big. Use Open in GitHub.")
            )
        }
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

private extension View {
    /// The system's Back and Forward on the Mac walk a history, which is not where a PR came from. This is one Back, which
    /// does what the stack says (`PullRequestBack`).
    @ViewBuilder func macBackButton() -> some View {
        #if os(macOS)
        modifier(MacBackButton())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacBackButton: ViewModifier {
    @Environment(\.pullRequestBack) private var back

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { back?() }
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
    }
}
#endif
