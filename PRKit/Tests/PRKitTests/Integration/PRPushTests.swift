import Foundation
import PRContractFixtures
@testable import PRKit
import Testing

/// A pr-worker push, read where it arrives (docs/api.md, "Alerts").
struct PRPushTests {
    /// PRKit/Tests/PRContractFixtures/Fixtures/alert.json, which the worker's contract test writes from the real builder.
    static func fixture(_ name: String) throws -> [AnyHashable: Any] {
        try #require(JSONSerialization.jsonObject(with: ContractFixtures.data(name)) as? [AnyHashable: Any])
    }

    @Test func theWorkersAlertOpensItsPR() throws {
        let push = try PRPush(userInfo: Self.fixture("alert.json"))
        #expect(push == .alert(kind: .reviewRequested, pullRequest: PullRequestRef(repo: "acme/app", number: 7)))
        #expect(push?.openedPullRequest == PullRequestRef(repo: "acme/app", number: 7))
    }
}
