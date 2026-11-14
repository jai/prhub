import Foundation
import PRKitCore
import Testing

/// A review Ask AI drafted, as the Worker sends it under an answer (docs/api.md, "Drafted reviews").
struct PRAskDraftTests {
    @Test func anAnswerCarriesItsDraftedReviewAndAnOlderOneHasNone() throws {
        let json = """
        {"messages": [
          {"id": "q", "role": "you", "text": "Write the review", "anchor": null},
          {"id": "a", "role": "agent", "text": "Drafted.", "anchor": null, "draft": {
            "event": "REQUEST_CHANGES", "body": "The retry loses the error.",
            "comments": [{"path": "src/a.ts", "line": 12, "side": "RIGHT", "body": "Keep the cause."}]}}
        ], "isWorking": false}
        """
        let chat = try JSONDecoder().decode(PRAskChat.self, from: Data(json.utf8))
        #expect(chat.messages[0].draft == nil)
        let draft = try #require(chat.messages[1].draft)
        #expect(draft.reviewEvent == .requestChanges)
        let comments = draft.draftComments
        #expect(comments.map(\.path) == ["src/a.ts"])
        #expect(comments.first?.side == .right)
        #expect(comments.first?.line == 12)
    }

    @Test func anEventThisAppSendsNoReviewForIsNoReview() {
        let draft = PRAskDraft(event: .approve, body: "", comments: [])
        #expect(draft.reviewEvent == .approve)
        let odd = try? JSONDecoder().decode(PRAskDraft.self, from: Data(#"{"event":"MERGE","body":"","comments":[]}"#.utf8))
        #expect(odd?.reviewEvent == nil)
    }
}
