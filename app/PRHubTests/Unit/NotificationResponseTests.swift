import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing
import UserNotifications

@MainActor
struct NotificationResponseTests {
    private static let ref = PullRequestRef(repo: "acme/app", number: 7)

    private static let alert: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Review requested: acme/app#7", "body": "Add the retry"]],
        "reason": "pr_alert", "kind": "review_requested", "pr": ["repo": "acme/app", "number": 7],
    ]

    @Test func tappingAnAlertOpensThePRAndDismissingOpensNothing() async {
        let opened = Shared<[PullRequestRef]>([])
        let delegate = PRHubNotificationDelegate { ref, _ in opened.with { $0.append(ref) } }
        for action in [UNNotificationDismissActionIdentifier, UNNotificationDefaultActionIdentifier] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                delegate.respond(action: action, pullRequest: PRPush(userInfo: Self.alert)?.openedPullRequest) {
                    continuation.resume()
                }
            }
        }
        #expect(opened.with { $0 } == [Self.ref])
    }
}
