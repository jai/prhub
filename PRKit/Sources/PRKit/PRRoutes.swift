import PRKitCore
import PRKitDesign
import SwiftUI

/// A PR's screen on a navigation stack: the PR, or its diff pushed over it, so Back from the diff is the PR.
enum PRRoute: Hashable {
    case pullRequest(PRSession)
    case diff(PRSession)

    var session: PRSession {
        switch self {
        case let .pullRequest(session), let .diff(session): session
        }
    }

    /// What opening a PR pushes: the PR, and its diff over it when the diff was asked for.
    static func opening(_ session: PRSession, showsDiff: Bool) -> [PRRoute] {
        showsDiff ? [.pullRequest(session), .diff(session)] : [.pullRequest(session)]
    }
}

/// What a PR's screens do to the stack they are on.
@MainActor
struct PRStack {
    /// Puts these screens on the stack: on top of it, or from the iPad's list in place of the PR on show.
    let show: ([PRRoute]) -> Void
    /// One screen back: from a diff to its PR.
    let back: () -> Void
    /// Back from a PR, on the Mac: the PRs tab's returns to the list, another tab's goes one step.
    let backFromPullRequest: () -> Void
}

extension PRStack {
    /// A tab's stack of any screens, which a PR goes on top of.
    static func path(_ path: Binding<NavigationPath>, backGoesToRoot: Bool) -> PRStack {
        let back = {
            if !path.wrappedValue.isEmpty {
                path.wrappedValue.removeLast()
            }
        }
        return PRStack(
            show: { routes in
                var next = path.wrappedValue
                routes.forEach { next.append($0) }
                path.wrappedValue = next
            },
            back: back,
            backFromPullRequest: {
                if backGoesToRoot {
                    path.wrappedValue = NavigationPath()
                } else {
                    back()
                }
            }
        )
    }

    /// The PRs tab's own stack: a PR goes on top, and Back from a PR is the list.
    static func routes(_ routes: Binding<[PRRoute]>) -> PRStack {
        PRStack(
            show: { routes.wrappedValue += $0 },
            back: { _ = routes.wrappedValue.popLast() },
            backFromPullRequest: { routes.wrappedValue = [] }
        )
    }

    /// The iPad's list: a PR picked there replaces the one in the detail, and whatever was over it.
    static func replacing(_ routes: Binding<[PRRoute]>) -> PRStack {
        PRStack(
            show: { next in withAnimation(AppMotion.swap) { routes.wrappedValue = next } },
            back: { routes.wrappedValue = [] },
            backFromPullRequest: { routes.wrappedValue = [] }
        )
    }
}

/// Opens PRs on the stack it belongs to: a PR link, a row's Review shortcut, and a PR's own Review changes.
@MainActor
struct PullRequestOpener {
    let model: PRsModel
    let stack: PRStack

    func open(_ link: PRLink, source: PROpenReport.Source = .link) {
        stack.show(PRRoute.opening(model.session(for: link.ref, source: source), showsDiff: link.showsDiff))
    }

    /// The Review shortcut: the PR with its diff on top, and the panel open on its key lines.
    func review(_ ref: PullRequestRef, source: PROpenReport.Source = .link) {
        let session = model.session(for: ref, source: source)
        session.opensPanelOnArrival = true
        stack.show(PRRoute.opening(session, showsDiff: true))
    }

    /// Files changed: the diff over its PR, the panel waiting for its button.
    func showDiff(of session: PRSession) {
        stack.show([.diff(session)])
    }

    /// A PR's Review changes: its diff with the panel open on the key lines, as the Review shortcut lands.
    func reviewChanges(of session: PRSession) {
        session.opensPanelOnArrival = true
        stack.show([.diff(session)])
    }
}

extension EnvironmentValues {
    @Entry var pullRequestOpener: PullRequestOpener?
    /// The PRs tab draws the review toast over all of itself; a PR pushed on another tab's stack draws its own.
    @Entry var showsReviewToastAbove = false
}

/// Goes on a `NavigationStack`, not inside it: pushed screens take their environment from the stack. A PR link in any of
/// them then pushes the PR on this stack, so Back returns to where the link was.
struct PullRequestLinks: ViewModifier {
    @Environment(PRsModel.self) private var model
    let stack: PRStack

    func body(content: Content) -> some View {
        let opener = PullRequestOpener(model: model, stack: stack)
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let link = PRLink(url: url) else {
                    return .systemAction
                }
                opener.open(link)
                return .handled
            })
            .environment(\.pullRequestOpener, opener)
    }
}

/// Goes inside the `NavigationStack`: a PR and its diff.
struct PullRequestDestination: ViewModifier {
    /// Handed on by name: on the Mac a pushed screen doesn't get what is set on its stack.
    @Environment(\.pullRequestOpener) private var opener
    @Environment(\.showsReviewToastAbove) private var toastAbove

    func body(content: Content) -> some View {
        content.navigationDestination(for: PRRoute.self) { route in
            Group {
                switch route {
                case let .pullRequest(session): PRScreen(session: session)
                case let .diff(session): PRDiffScreen(session: session)
                }
            }
            .overlay(alignment: .top) {
                if !toastAbove {
                    PRReviewToastView(model: route.session.model)
                }
            }
            .environment(\.pullRequestOpener, opener)
            .environment(\.showsReviewToastAbove, toastAbove)
            .pushedOnMac()
        }
    }
}

extension View {
    /// On a `NavigationStack` with `PRRoute`s in it, which its PR links push onto.
    func opensPullRequestLinks(on stack: PRStack) -> some View {
        modifier(PullRequestLinks(stack: stack))
    }
}
