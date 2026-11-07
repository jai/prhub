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
}
