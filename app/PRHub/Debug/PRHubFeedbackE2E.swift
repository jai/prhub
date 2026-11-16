#if DEBUG
    import FeatureKit
    import Foundation
    import PRKit

    /// Debug builds only. `-PRHubFeedbackE2E`: the Feedback tab straight on FeedbackKit's live Worker (its direct path,
    /// `FeedbackDirect`) as its test app, which an echo answers instead of an agent (issue #51). The Worker's root comes in
    /// `FEEDBACKKIT_E2E_URL` and a token the test signed with the test app's key in `FEEDBACKKIT_E2E_TOKEN`; without both
    /// this is nil and the launch is an ordinary one. The PRs are the samples.
    enum PRHubFeedbackE2E {
        @MainActor static func environment(_ values: [String: String] = ProcessInfo.processInfo.environment)
            -> PRHubEnvironment?
        {
            guard let root = values["FEEDBACKKIT_E2E_URL"].flatMap(URL.init(string:)),
                  let token = values["FEEDBACKKIT_E2E_TOKEN"], !token.isEmpty
            else {
                return nil
            }
            // FeedbackKit's direct path, as PRHub's own Feedback tab takes it when the Worker names a root.
            let feedback = FeatureClient(direct: FeedbackDirect(baseURL: root, token: { _ in token }))
            let environment = PRHubEnvironment.offline(
                config: DeviceConfig(features: [.feedback], login: "feedbackkit-e2e"), samples: .prHub,
                worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "feedback-e2e",
                isSample: false, feedbackClient: feedback
            )
            environment.navigation.selectedTab = .feedback
            return environment
        }
    }
#endif
