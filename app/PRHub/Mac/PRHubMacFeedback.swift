import FeatureKit
import PRHubCore
import PRKit
import PRKitDesign
import SwiftUI

/// The Feedback button in the PRs window's toolbar, and Window → Feedback (⇧⌘F): the phone's Feedback tab as a window
/// of its own, where the Worker serves it. The phone hides the tab where it does not, and the PRs window its button; a
/// window in the Window menu is always there, so it says so instead.
struct PRHubMacFeedback: View {
    static let windowID = "prhub-feedback"

    let environment: PRHubEnvironment
    @AppStorage(MacTextSize.key) private var textScale = MacTextSize.standard

    private var shown: PRHubEnvironment {
        environment.sample ?? environment
    }

    /// The Mac's list marks the open chat's row with the system's own fill, and `.primary` text over it turns white:
    /// on the row's card that was a white title on white. The label colours stay themselves.
    private static let theme: ChatTheme = {
        var theme = ChatTheme.prHub
        theme.ink = Color(nsColor: .labelColor)
        theme.inkQuiet = Color(nsColor: .secondaryLabelColor)
        return theme
    }()

    var body: some View {
        Group {
            if shown.connection.config?.isOn(.feedback) == true {
                FeatureRequestsView(model: shown.feedback)
                    // The chat whatever opened this window asked for, until the window closes.
                    .opening(shown.navigation.feedbackChat)
                    .onDisappear { shown.navigation.feedbackChat = nil }
                    .chatTheme(Self.theme)
                    // The view keeps its first model: another path's model is another view.
                    .id(ObjectIdentifier(shown.feedback))
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
        .onChange(of: environment.feedbackPathWanted) { environment.followFeedbackPath() }
        .font(.appBody)
        .id(textScale)
        .frame(minWidth: 640, minHeight: 480)
    }
}
