import Foundation
@testable import PRKit
import Testing

/// Line comments waiting to go with a review (`PRDraftStore`).
struct PRDraftsTests {
    @Test func draftsOutliveTheSessionAndGoWhenCleared() {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = PRDraftStore(directory: directory)
        let ref = PullRequestRef(repo: "o/r", number: 7)
        let draft = PRDraftComment(id: UUID(), path: "f", line: 1, side: .right, body: "b")

        store.save([draft], for: ref)
        #expect(PRDraftStore(directory: directory).load(ref) == [draft])
        store.save([], for: ref)
        #expect(store.load(ref).isEmpty)
    }

    // An answered row was rebuilt without `tickets`, so a PR with two tickets showed one once reviewed.
}
