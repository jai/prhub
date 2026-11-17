import Observation
import PRKit

public enum PRHubTab: Hashable, Sendable {
    case prs
    /// The Worker's feature requests, when it serves them (`features.feedback`).
    case feedback
    case settings
}

/// Which tab shows, and the PRs tab that opens a PR from a link or an alert.
@MainActor
@Observable
public final class PRHubNavigation {
    public var selectedTab: PRHubTab = .prs
    @ObservationIgnored private weak var pullRequests: PRKitController?

    init(pullRequests: PRKitController) {
        self.pullRequests = pullRequests
    }

    func showPullRequest(_ ref: PullRequestRef) {
        pullRequests?.open(ref)
        selectedTab = .prs
    }

    /// A tapped alert's PR, with the row it carried.
    func showAlert(_ ref: PullRequestRef, row: PullRequestRow?) {
        pullRequests?.open(alert: ref, row: row)
        selectedTab = .prs
    }
}
