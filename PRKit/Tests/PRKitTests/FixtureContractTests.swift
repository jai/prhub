import Foundation
import Testing
@testable import PRKit

/// The worker's golden fixtures (docs/fixtures/), which its contract test writes from the real builders: the app reads
/// each one as it reads the Worker's answer. A field the Worker renames or drops fails here before a phone sees it.
@Suite(.enabled(if: RepoFixtures.areHere, "reads docs/fixtures/ from the repo"))
struct FixtureContractTests {
    static func data(_ name: String) throws -> Data {
        try RepoFixtures.data(name)
    }

    @Test func aListRowDecodes() throws {
        let row = try JSONDecoder().decode(PullRequestRow.self, from: Self.data("row.json"))
        #expect(row.repo == "acme/app" && row.number == 7)
        #expect(row.isReviewRequest)
        #expect(row.reviewDue != nil)
        #expect(row.keyLines == 100)
        #expect(row.listPullRequest.author == "alex")
        #expect(row.ticket?.key == "ENG-7" && row.ticket?.found == true)
        #expect(row.ticket?.stateText == "In Progress" && row.ticket?.stateColor == "#f2c94c")
    }

    @Test func aMergedRowDecodes() throws {
        let row = try JSONDecoder().decode(PullRequestRow.self, from: Self.data("merged-row.json"))
        #expect(row.isMerged)
        #expect(row.keyLines == nil)
        #expect(row.status?.mergedAt != nil)
    }

    @Test func aDetailDecodes() throws {
        let detail = try PullRequestDetail.decode(Self.data("detail.json"))
        #expect(detail.listState == .open)
        #expect(!detail.listedChecks.isEmpty)
        #expect(detail.body == "Retries a failed upload twice.")
    }
}
