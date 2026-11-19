import Foundation
@testable import PRKit
import Testing

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

    @Test func aTicketsOwnerDecodesAndAnOlderWorkersTicketHasNone() throws {
        let owned = #"{"key": "ENG-7", "url": null, "title": "Retry", "state": "Todo", "state_type": "unstarted", "#
            + #""state_color": null, "assignee": "Alex Doe", "found": true}"#
        let ticket = try JSONDecoder().decode(PRListTicket.self, from: Data(owned.utf8))
        #expect(ticket.assignee == "Alex Doe" && ticket.ownerShortName == "Alex")
        #expect(try JSONDecoder().decode(PRListTicket.self, from: JSONEncoder().encode(ticket)) == ticket)
        let older = #"{"key": "ENG-7", "url": null, "title": "Retry", "state": "Todo", "found": true}"#
        #expect(try JSONDecoder().decode(PRListTicket.self, from: Data(older.utf8)).assignee == nil)
        let nobody = #"{"key": "ENG-7", "assignee": null, "found": true}"#
        #expect(try JSONDecoder().decode(PRListTicket.self, from: Data(nobody.utf8)).ownerShortName == nil)
    }

    static func ticket(_ key: String) -> PRListTicket {
        PRListTicket(key: key, title: key, state: "Todo", stateType: "unstarted", found: true)
    }

    @Test func aRowsTicketsDecodeInOrder() throws {
        let one = { (key: String) in #"{"key": "\#(key)", "url": null, "title": "\#(key)", "state": "Todo", "#
            + #""state_type": "unstarted", "state_color": null, "found": true}"#
        }
        let json = Self.row + #", "ticket": \#(one("DEVOP-1")), "tickets": [\#(one("DEVOP-1")), \#(one("DEVOP-2"))]}"#
        let row = try JSONDecoder().decode(PullRequestRow.self, from: Data(json.utf8))
        #expect(row.tickets?.map(\.key) == ["DEVOP-1", "DEVOP-2"])
        #expect(try JSONDecoder().decode(PullRequestRow.self, from: Data((Self.row + "}").utf8)).tickets == nil)
    }

    @Test func aTitlesBracketGoesOnlyWhenEveryKeyInItHasItsTicketLine() throws {
        let pullRequest = try Self.listPullRequest(#", "title": "fix: Do something [DEVOP-1, DEVOP-2]""#)
        let title = { (tickets: [PRListTicket]) in
            PRListItem(ticket: tickets.first, moreTickets: Array(tickets.dropFirst()), pullRequests: [pullRequest])
                .title(of: pullRequest)
        }
        #expect(title([Self.ticket("DEVOP-1"), Self.ticket("DEVOP-2")]) == "fix: Do something")
        #expect(title([Self.ticket("DEVOP-1")]) == "fix: Do something [DEVOP-1, DEVOP-2]", "DEVOP-2 has no line")
        #expect(title([]) == "fix: Do something [DEVOP-1, DEVOP-2]")
        let two = try Self.listPullRequest(#", "title": "Retry [API-88] [sec-12]""#)
        let item = PRListItem(ticket: Self.ticket("API-88"), moreTickets: [Self.ticket("SEC-12")], pullRequests: [two])
        #expect(item.title(of: two) == "Retry")
        let single = try Self.listPullRequest(#", "title": "Retry [ENG-7]""#)
        #expect(PRListItem(ticket: Self.ticket("ENG-7"), pullRequests: [single]).title(of: single) == "Retry")
    }

    @Test func unresolvedAndMissingRefsDecodeWithTheirFieldsNull() throws {
        let json = #"""
        {"ticket": {"key": "ENG-8", "url": "https://linear.app/acme/issue/ENG-8", "title": null, "state": null,
                    "state_type": null, "found": null, "resolved_at": null},
         "prs": [{"repo": "acme/web", "number": 8, "url": "https://github.com/acme/web/pull/8",
                  "title": null, "state": null, "checks": null, "merge": null, "review": null,
                  "created_at": null, "author": null, "found": null, "resolved_at": null},
                 {"repo": "acme/tools", "number": 9, "url": "https://github.com/acme/tools/pull/9",
                  "title": null, "state": null, "checks": null, "merge": null, "review": null,
                  "created_at": null, "author": null, "found": false, "resolved_at": "2026-10-28T05:00:16Z"}],
         "title": "Retry uploads on timeout", "note": null}
        """#
        let item = try Self.decoder.decode(PRListItem.self, from: Data(json.utf8))
        #expect(item.ticket?.found == nil && item.ticket?.title == nil && item.ticket?.resolvedAt == nil)
        #expect(item.ticket?.url == "https://linear.app/acme/issue/ENG-8")
        #expect(item.pullRequests.map(\.found) == [nil, false])
        #expect(item.pullRequests.allSatisfy { $0.status.state == nil && $0.createdAt == nil })
        #expect(item.pullRequests.last?.resolvedAt != nil)
        let noURL = try Self.decoder.decode(PRListTicket.self, from: Data(#"{"key":"ENG-9","url":null,"found":null}"#.utf8))
        #expect(noURL.url == nil && noURL.found == nil)
    }

    @Test func aStateWordThisBuildDoesNotKnowReadsAsNoState() throws {
        let json = #"""
        {"repo":"acme/tools","number":9,"url":"https://github.com/acme/tools/pull/9",
         "title":"Lists","state":"queued","checks":"skipped","merge":"clean","review":"dismissed",
         "created_at":"2026-10-27T05:00:00Z","author":null,"found":true,"resolved_at":"2026-10-28T05:00:16Z"}
        """#
        let pullRequest = try Self.decoder.decode(PRListPullRequest.self, from: Data(json.utf8))
        #expect(pullRequest.status.state == nil && pullRequest.status.checks == nil)
        #expect(pullRequest.status.merge == .clean && pullRequest.status.review == nil)
        #expect(pullRequest.status.statusText == "unknown")
    }
}
