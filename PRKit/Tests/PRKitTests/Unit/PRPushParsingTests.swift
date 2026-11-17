import Foundation
@testable import PRKit
import Testing

struct PRPushParsingTests {
    @Test func theSilentWakeIsASyncAndOpensNothing() {
        let push = PRPush(userInfo: ["aps": ["content-available": 1], "reason": "pr_sync"])
        #expect(push == .sync)
        #expect(push?.openedPullRequest == nil)
    }

    @Test func aKindThisBuildDoesNotKnowStillOpensThePR() {
        let push = PRPush(userInfo: [
            "reason": "pr_alert", "kind": "merged", "pr": ["repo": "jai/agent-pager", "number": 28],
        ])
        let ref = PullRequestRef(repo: "jai/agent-pager", number: 28)
        #expect(push == .alert(kind: .unknown("merged"), pullRequest: ref))
        #expect(PRPush(userInfo: ["reason": "pr_alert", "pr": ["repo": "a/b", "number": 1]])?.openedPullRequest != nil)
    }

    @Test func anAlertThatNamesNoPRAndOtherPushesAreNotPRPushes() {
        for userInfo: [AnyHashable: Any] in [
            ["reason": "pr_alert", "kind": "approved"],
            ["reason": "pr_alert", "pr": ["repo": "no-owner", "number": 3]],
            ["reason": "pr_alert", "pr": ["repo": "a/b", "number": 0]],
            ["reason": "pr_alert", "pr": ["repo": "a/b", "number": "3"]],
            ["reason": "health_check"],
            ["alert_id": "a1", "severity": "high"],
        ] {
            #expect(PRPush(userInfo: userInfo) == nil, "\(userInfo)")
        }
    }
}
