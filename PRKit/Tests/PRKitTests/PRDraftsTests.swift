import Foundation
import Testing
@testable import PRKit

/// Line comments waiting to go with a review (`PRDraftStore`).
struct PRDraftsTests {
    @Test func draftsOutliveTheSessionAndGoWhenCleared() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = PRDraftStore(directory: directory)
        let ref = PullRequestRef(repo: "o/r", number: 7)
        let draft = PRDraftComment(id: UUID(), path: "f", line: 1, side: .right, body: "b")

        store.save([draft], for: ref)
        #expect(PRDraftStore(directory: directory).load(ref) == [draft])
        store.save([], for: ref)
        #expect(store.load(ref).isEmpty)
    }

    @Test func aReviewSendsItsDraftsWithoutThePhonesIds() throws {
        let draft = PRDraftComment(id: UUID(), path: "f", line: 1, side: .right, body: "b")
        let write = PRWrite.review(.comment, body: "", commit: "c", comments: [draft])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any]
        let comments = try #require(encoded?["comments"] as? [[String: AnyHashable]])
        #expect(comments == [["path": "f", "line": 1, "side": "RIGHT", "body": "b"]])
    }

    /// An answered row was rebuilt without `tickets`, so a PR with two tickets showed one once reviewed.
    @Test func anAnsweredRowKeepsEveryTicket() throws {
        let tickets = try JSONDecoder().decode(
            [PRListTicket].self, from: Data(#"[{"key": "API-88", "found": true}, {"key": "SEC-12", "found": true}]"#.utf8)
        )
        let status = PullRequestRow.Status(
            list: "review", author: "mona", checks: "passing", review: "required", merge: "clean", jaiReview: nil,
            jaiReviewedAt: nil
        )
        let row = PullRequestRow(
            repo: "o/r", number: 7, title: "t", head: "h", revision: "r", diff: .ready, detail: "d", status: status,
            ticket: tickets[0], tickets: tickets
        )
        let answered = row.answered(PRLocalAnswer(review: "approved", sentAt: "2026-11-14T00:00:00Z", head: "h"))
        #expect(answered.isAnswered && answered.tickets == tickets && answered.ticket == tickets[0])
    }
}
