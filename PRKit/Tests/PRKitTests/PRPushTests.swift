import Foundation
import Testing
@testable import PRKit

/// A pr-worker push, read where it arrives (docs/api.md, "Alerts").
struct PRPushTests {
    /// docs/fixtures/alert.json, which the worker's contract test writes from the real builder.
    static func fixture(_ name: String) throws -> [AnyHashable: Any] {
        try #require(JSONSerialization.jsonObject(with: RepoFixtures.data(name)) as? [AnyHashable: Any])
    }

    @Test(.enabled(if: RepoFixtures.areHere)) func theWorkersAlertOpensItsPR() throws {
        let push = PRPush(userInfo: try Self.fixture("alert.json"))
        #expect(push == .alert(kind: .reviewRequested, pullRequest: PullRequestRef(repo: "acme/app", number: 7)))
        #expect(push?.openedPullRequest == PullRequestRef(repo: "acme/app", number: 7))
    }

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
