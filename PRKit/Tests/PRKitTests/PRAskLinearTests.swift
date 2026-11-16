import Foundation
import PRKitCore
import Testing

/// A Linear comment Ask AI proposed, as the Worker sends it under an answer (docs/api.md, "Commenting on Linear").
struct PRAskLinearTests {
    @Test func anAnswerCarriesItsProposedCommentsAndWhereEachStands() throws {
        let json = """
        {"messages": [
          {"id": "q", "role": "you", "text": "Tag Octbot on the ticket", "anchor": null},
          {"id": "a", "role": "agent", "text": "Drafted.", "anchor": null, "linear": [
            {"issue": "ENG-12", "text": "@Octo Bot rename the flag",
             "mentions": [{"written": "Octbot", "user": {"name": "Octo Bot", "display_name": "octobot", "agent": true}}],
             "problem": null, "state": "posted", "url": "https://linear.app/acme/issue/ENG-12#comment-1", "failure": null,
             "session": {"id": "s1", "agent": "Octo Bot", "status": "active",
                         "url": "https://linear.app/acme/agent-session/s1"}},
            {"issue": "ENG-12", "text": "@Nobody look", "mentions": [{"written": "Nobody", "user": null}],
             "problem": "No one in Linear matches @Nobody.", "state": "proposed", "url": null, "failure": null,
             "session": null}
          ]}
        ], "isWorking": false}
        """
        let chat = try JSONDecoder().decode(PRAskChat.self, from: Data(json.utf8))
        #expect(chat.messages[0].linear == nil)
        let cards = try #require(chat.messages[1].linear)
        #expect(cards[0].state == .posted)
        #expect(cards[0].canPost == false, "a posted comment posts no more")
        #expect(cards[0].mentions.first?.user == .init(name: "Octo Bot", agent: true))
        #expect(cards[0].session?.status == "active")
        #expect(cards[0].session?.url?.absoluteString == "https://linear.app/acme/agent-session/s1")
        #expect(cards[1].canPost == false, "a mention that reaches nobody can't post")
        #expect(cards[1].mentions.first?.user == nil)
    }

    @Test func aFailedPostCanBeTriedAgain() {
        let card = PRAskLinearCard(issue: "ENG-12", text: "@Octo Bot hi", mentions: [], problem: nil, state: .failed,
                                   failure: "Linear refused: Issue is archived.")
        #expect(card.canPost)
    }
}
