import Observation
import PRKit

public enum PRHubTab: Hashable, Sendable {
    case prs
    /// The Worker's feature requests, when it serves them (`features.feedback`).
    case feedback
    case settings
}

/// A part of Settings that something else opens Settings at.
public enum PRHubSettingsSection: Hashable, Sendable {
    case linear
}

/// Which tab shows, and the PRs tab that opens a PR from a link or an alert.
@MainActor
@Observable
public final class PRHubNavigation {
    public var selectedTab: PRHubTab = .prs
    /// Where Settings scrolls to when it next shows; Settings clears it once there.
    public var settingsSection: PRHubSettingsSection?
    @ObservationIgnored private weak var pullRequests: PRKitController?

    init(pullRequests: PRKitController) {
        self.pullRequests = pullRequests
    }

    /// Settings at Linear: where a ticket line that says "Connect Linear to see this ticket" goes.
    public func showLinearSettings() {
        settingsSection = .linear
        selectedTab = .settings
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
