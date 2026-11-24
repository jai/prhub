import FeatureKit
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
    /// The feedback chat a tapped push asked for, until Feedback leaves the screen: Feedback opens on it
    /// (`FeedbackRequestsView.opening`).
    public var feedbackChat: FeedbackOpenRequest?
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

    /// A tapped push of a feedback chat: Feedback, on that chat. Each tap is a new request, so the same chat's next
    /// push opens it again.
    func showFeedbackChat(_ chat: String) {
        feedbackChat = FeedbackOpenRequest(chat: chat)
        selectedTab = .feedback
    }

    /// A tapped alert's PR, with the row it carried.
    func showAlert(_ ref: PullRequestRef, row: PullRequestRow?) {
        pullRequests?.open(alert: ref, row: row)
        selectedTab = .prs
    }
}
