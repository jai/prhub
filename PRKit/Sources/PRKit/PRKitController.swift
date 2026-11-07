import Foundation
import Observation
import PRKitCore
import SwiftUI

/// The PRs tab's one object, made once by the host at launch and kept: a silent push syncs PRs with no scene on
/// screen. Messages in are its methods; messages out go to `PRKitHost.receive`.
@MainActor
@Observable
public final class PRKitController {
    let model: PRsModel
    let navigation = PRNavigation()
    @ObservationIgnored let launchOptions: PRKitLaunchOptions

    public init(host: some PRKitHost) {
        let client = PRViewerClient(access: host.access, isInForeground: { await host.isInForeground() })
        model = PRsModel(client: client, samples: host.samples)
        launchOptions = host.launchOptions
        model.outboxSource = { host.outbox }
        model.apnsEnvironment = host.apnsEnvironment
        model.featureSource = { host.configuration }
        model.onEvent = { host.receive($0) }
        model.logFailures { line in Task { @MainActor in host.log(line) } }
    }

    /// For a test: a model made by hand.
    init(model: PRsModel) {
        self.model = model
        launchOptions = .none
    }

    /// The pr-worker client the PR screens use, for whatever else of the host talks to the same Worker.
    public var client: PRViewerClient {
        model.client
    }

    /// A wake or a foreground: brings the list up to date. One that finds a sync running waits for it.
    @discardableResult
    public func refresh(_ trigger: PRSyncTrigger) async -> PRSyncOutcome {
        await model.refresh(trigger)
    }

    /// The push token, kept for this launch; it goes to a Worker that pushes, now and at each foreground sync.
    public func register(apnsToken: String) {
        model.register(apnsToken: apnsToken)
    }

    /// After a pairing, or a config that turned push on: the token this launch already has.
    public func registerKnownToken() {
        model.registerKnownToken()
    }

    /// Shows this PR on the PRs tab, over nothing else. The host selects the tab.
    public func open(_ ref: PullRequestRef) {
        open(PRLink(ref: ref))
    }

    /// Shows this PR on the PRs tab, over nothing else, with its diff on top when the link asks for it (GitHub's
    /// `/files`): Back from the diff is the PR. The host selects the tab.
    public func open(_ link: PRLink) {
        navigation.pendingLink = link
    }

    /// Shows the PR that `text` names — a github.com PR link or `owner/repo#N` (`PRLinkParser`) — and says whether
    /// it named one. The way in for a link, and later for the clipboard, a share sheet or a quick jump.
    @discardableResult
    public func open(text: String) -> Bool {
        guard let link = PRLinkParser.link(in: text) else {
            return false
        }
        open(link)
        return true
    }

    /// How many screens are pushed over the list: a PR, and its diff over it.
    public var openCount: Int {
        navigation.routes.count
    }

    /// Back to the list: the tab picked again while it shows.
    public func popToRoot() {
        navigation.routes = []
    }

    /// PRHub's Disconnect: the rows, the mirror's files, the answers and the filter, so another Worker's PRs start
    /// from nothing.
    public func forgetEverything() {
        model.forgetEverything()
    }

    /// GitHub's answer to an outbox item (`PRKitOutbox`).
    public func outboxAnswered(id: String, data: Data) {
        model.outboxAnswered(id: id, data: data)
    }

    /// GitHub's refusal of an outbox item, in its own words.
    public func outboxRefused(id: String, reason: String) {
        model.outboxRefused(id: id, reason: reason)
    }
}

/// What the PRs tab has open. Held by the controller, so nothing a tab does to its view can drop an open PR, and the same
/// screens show whichever way the tab is laid out: on a narrow screen a stack over the list; on a wide one the first PR
/// beside the list, with the rest stacked over it.
@MainActor
@Observable
final class PRNavigation {
    var routes: [PRRoute] = []
    /// A PR opened from a link anywhere in the app: the PRs tab shows it, then sets this back to `nil`.
    var pendingLink: PRLink?

    /// The PR beside the list on a wide screen.
    var selected: PRSession? {
        guard case let .pullRequest(session) = routes.first else {
            return nil
        }
        return session
    }

    /// What is stacked over that PR: its diff, and any PR a link in it opened.
    var detailRoutes: [PRRoute] {
        get { Array(routes.dropFirst()) }
        set { routes = Array(routes.prefix(1)) + newValue }
    }

    /// The diff on show, if one is: on a wide screen it takes the list's room, and the keyboard steps through it.
    var diffOnShow: PRSession? {
        guard case let .diff(session) = routes.last else {
            return nil
        }
        return session
    }

    var showsDiff: Bool {
        diffOnShow != nil
    }
}

/// The PRs tab: the host puts it in a tab of its own.
public struct PRKitRoot: View {
    let kit: PRKitController

    public init(_ kit: PRKitController) {
        self.kit = kit
    }

    public var body: some View {
        PRsView(model: kit.model, navigation: kit.navigation, launchOptions: kit.launchOptions)
            .environment(kit.model)
    }
}

extension View {
    /// On the host's root, over every tab: a PR link on any of them can then open the PR there
    /// (`opensPullRequestLinks`).
    public func prKitEnvironment(_ kit: PRKitController) -> some View {
        environment(kit.model)
    }

    /// On a `NavigationStack`: PR links in it push the PR on this stack (the phone); elsewhere they open as links. A
    /// link to a PR's files pushes its diff over it, and a PR row's Review shortcut does the same.
    public func opensPullRequestLinks(in path: Binding<NavigationPath>, backGoesToRoot: Bool = false) -> some View {
        opensPullRequestLinks(on: .path(path, backGoesToRoot: backGoesToRoot))
    }

    /// Inside that stack: where those PRs and their diffs land.
    public func showsPullRequests() -> some View {
        modifier(PullRequestDestination())
    }
}
