import Foundation
import PRContractFixtures
@testable import PRKit
import Testing

/// The Worker produces these bundled payloads; the app decodes them through its real models.
/// A renamed or missing field fails here before it reaches a phone.
struct FixtureContractTests {
    static func data(_ name: String) throws -> Data {
        try ContractFixtures.data(name)
    }

    @Test func `a missing fixture fails instead of skipping coverage`() {
        #expect(throws: CocoaError.self) { try ContractFixtures.data("missing-fixture.json") }
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
        #expect(row.ticket?.assignee == "Alex Doe" && row.tickets?.first?.assignee == "Alex Doe")
        #expect(row.ticket?.delegate == "Atlas")
        #expect(row.ticket?.delegateAvatar == "https://avatars.linear.app/atlas.png")
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
