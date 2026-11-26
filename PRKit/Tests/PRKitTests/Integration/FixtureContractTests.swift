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

    @Test func aBotsRowNamesTheTicketsOwner() throws {
        let row = try JSONDecoder().decode(PullRequestRow.self, from: Self.data("bot-row.json"))
        #expect(row.status?.author == "atlas-bot")
        #expect(row.status?.requestedBy?.name == "Alex Doe" && row.status?.requestedBy?.login == nil)
        #expect(row.status?.agent == nil && row.ticket?.delegate == nil, "the ticket is not delegated")
        #expect(row.listPullRequest.whoLine == "Alex via atlas-bot")
        #expect(row.listPullRequest.avatarURL?.absoluteString == "https://avatars.linear.app/alex.png")
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
        #expect(detail.createdAt == ISO8601DateFormatter().date(from: "2026-11-05T02:00:00Z"), "when it was opened")
    }

    /// Written by hand to the Worker's shape (docs/api.md), beside the Worker's own `detail.json`: a detail whose
    /// person has a pending review on GitHub, with a line comment, a file comment and a reply to a posted thread.
    @Test func aDetailWithAPendingReviewDecodes() throws {
        let detail = try PullRequestDetail.decode(Self.data("detail-pending-review.json"))
        #expect(detail.pendingReview.isSupported)
        let comments = detail.pendingReview.comments
        #expect(comments.map(\.id) == ["PRRC_kwDOAcme1", "PRRC_kwDOAcme2", "PRRC_kwDOAcme3"])
        #expect(comments[0].path == "src/upload.ts" && comments[0].line == 12 && comments[0].side == .right)
        #expect(comments[1].isFile && comments[1].line == nil)
        #expect(comments[2].thread == "PRRT_kwDOAcme1" && comments[2].isOutdated)
    }

    /// A detail as a Worker from before pending reviews sends it: no `pendingReview` key, so the app keeps comments
    /// on the device as it did.
    @Test func aDetailFromBeforePendingReviewsStillDecodes() throws {
        let detail = try PullRequestDetail.decode(Self.data("detail-before-pending-review.json"))
        #expect(detail.pendingReview == .unsupported)
        #expect(detail.body == "Retries a failed upload twice.")
    }
}
