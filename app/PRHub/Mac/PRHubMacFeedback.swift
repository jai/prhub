import FeatureKit
import PRHubCore
import PRKit
import PRKitDesign
import SwiftUI

/// Window → Feedback (⇧⌘F): the phone's Feedback tab as a window of its own, where the Worker serves it. The phone
/// hides the tab where it does not; a window in the Window menu is always there, so it says so instead.
struct PRHubMacFeedback: View {
    static let windowID = "prhub-feedback"

    let environment: PRHubEnvironment
    @AppStorage(MacTextSize.key) private var textScale = MacTextSize.standard

    private var shown: PRHubEnvironment {
        environment.sample ?? environment
    }

    var body: some View {
        Group {
            if shown.connection.config?.isOn(.feedback) == true {
                FeatureRequestsView(model: shown.feedback)
            } else {
                ContentUnavailableView(
                    "No Feedback here", systemImage: AppIcon.conversation.symbol,
                    description: Text(
                        shown.isSample
                            ? "Feedback opens once you sign in. The sample PRs have none."
                            : "This Worker doesn't take feedback."
                    )
                )
                .accessibilityIdentifier("prhub-feedback-unavailable")
            }
        }
        .prKitEnvironment(shown.prs)
        // Open on its own, this window follows the Worker's FeedbackKit path too.
        .onChange(of: environment.connection.config?.feedbackDirect) { environment.followFeedbackPath() }
        .font(.appBody)
        .id(textScale)
        .frame(minWidth: 480, minHeight: 480)
    }
}
