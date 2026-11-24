#if DEBUG
    import FeatureKit
    import Foundation

    extension FeatureSamples {
        /// `-PRHubFeedback`: two feedback chats and the agent's answer to anything sent, with no Worker.
        static let prHub = FeatureSamples(
            list: FeedbackList(
                threads: [
                    FeedbackThread(
                        id: "fb_sample_ticket", title: "Open a PR's Linear ticket from its page",
                        createdAt: "2026-11-20T09:00:00Z"
                    ),
                    FeedbackThread(
                        id: "fb_sample_filter", title: "Remember the org filter between launches",
                        createdAt: "2026-11-18T14:20:00Z"
                    ),
                ],
                builderOnline: true
            ),
            chat: { id in
                FeedbackChat(
                    id: id,
                    messages: id == "fb_sample_ticket"
                        ? [
                            .init(id: "1", role: "you", text: "Open a PR's Linear ticket from its page"),
                            .init(id: "2", role: "agent", text: "Done: the ticket is a button on the PR. Shipped in build 310."),
                        ]
                        : [
                            .init(id: "1", role: "you", text: "Remember the org filter between launches"),
                            .init(id: "2", role: "agent", text: "The filter is kept now. Shipped in build 305."),
                        ],
                    isWorking: false, activity: nil, problem: nil, costCents: nil, builderOnline: true
                )
            },
            answer: "Got it. I'll make the change, test it on the iPhone and the Mac, and reply here with the build."
        )
    }
#endif
