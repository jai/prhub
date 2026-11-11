import Foundation
import Testing
@testable import PRKit

/// What the phone reads from a row's `ticket` and a list PR's `review_due_at`, and what an older Worker's answer reads as.
struct PRListDecodeTests {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func listPullRequest(_ extra: String) throws -> PRListPullRequest {
        let json = #"{"repo": "acme/app", "number": 7, "url": "https://github.com/acme/app/pull/7", "found": true"#
            + extra + "}"
        return try decoder.decode(PRListPullRequest.self, from: Data(json.utf8))
    }

    @Test func aListPullRequestCarriesItsReviewDueTime() throws {
        let due = try Self.listPullRequest(#", "review_due_at": "2026-11-09T03:00:00Z""#).reviewDueAt
        #expect(due == Date(timeIntervalSince1970: 1_794_193_200))
        #expect(try Self.listPullRequest(#", "review_due_at": null"#).reviewDueAt == nil)
        #expect(try Self.listPullRequest("").reviewDueAt == nil, "a Worker older than it")
        let bad = try Self.listPullRequest(#", "review_due_at": "Monday""#)
        #expect(bad.reviewDueAt == nil && bad.status.number == 7, "a bad due time spoils nothing else")
    }

    static let row = #"""
        {"repo": "acme/app", "number": 7, "title": "Retry uploads", "head": "abc", "revision": "abc-main",
         "diff": "ready", "detail": "v1", "status": null, "keyLines": null
        """#

    @Test func aRowsTicketDecodesAndAnOlderWorkersRowHasNone() throws {
        let ticket = #""ticket": {"key": "ENG-7", "url": "https://linear.app/acme/issue/ENG-7", "title": "Retry", "#
            + ##""state": "Done", "state_type": "completed", "state_color": "#5e6ad2", "found": true}"##
        let row = try JSONDecoder().decode(PullRequestRow.self, from: Data((Self.row + ", \(ticket)}").utf8))
        #expect(row.ticket == PRListTicket(
            key: "ENG-7", url: "https://linear.app/acme/issue/ENG-7", title: "Retry", state: "Done",
            stateType: "completed", stateColor: "#5e6ad2", found: true
        ))
        let kept = try JSONDecoder().decode(PullRequestRow.self, from: JSONEncoder().encode(row))
        #expect(kept == row, "the phone keeps the ticket with the row")
        #expect(try JSONDecoder().decode(PullRequestRow.self, from: Data((Self.row + "}").utf8)).ticket == nil)
        let none = try JSONDecoder().decode(PullRequestRow.self, from: Data((Self.row + #", "ticket": null}"#).utf8))
        #expect(none.ticket == nil)
    }
}
