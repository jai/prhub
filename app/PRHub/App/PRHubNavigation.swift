import Observation
import PRKit

enum PRHubTab: Hashable, Sendable {
    case prs
    case settings
}

/// Which tab shows, and the PRs tab that opens a PR from a link or an alert.
@MainActor
@Observable
final class PRHubNavigation {
    var selectedTab: PRHubTab = .prs
    @ObservationIgnored private weak var pullRequests: PRKitController?

    init(pullRequests: PRKitController) {
        self.pullRequests = pullRequests
    }

    func showPullRequest(_ ref: PullRequestRef) {
        pullRequests?.open(ref)
        selectedTab = .prs
    }
}
