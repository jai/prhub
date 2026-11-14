import SwiftUI
import Testing
@testable import PRKit

/// "Wait, what?" (Jai, 2026-11-13): one tap under the agent's newest words asks it to say them again plainly. It shows
/// only while those words are the newest in the chat, and his bubble says "Wait, what?" while the agent gets the whole
/// request.
@MainActor
struct WaitWhatTests {
    private static func message(_ id: String, _ role: ChatMessage.Role) -> ChatMessage {
        ChatMessage(id: id, role: role, text: "Words \(id).")
    }

    @Test func itShowsUnderTheAgentsNewestWordsPastItsToolCalls() {
        let messages = [Self.message("1", .mine), Self.message("2", .theirs), Self.message("3", .tool(name: "Read"))]
        typealias Chat = ChatView<EmptyView, EmptyView, EmptyView, EmptyView>
        #expect(Chat.waitWhatID(in: messages) == "2")
    }

    @Test func itShowsNowhereOnceJaiHasSaidSomethingNewer() {
        typealias Chat = ChatView<EmptyView, EmptyView, EmptyView, EmptyView>
        #expect(Chat.waitWhatID(in: [Self.message("1", .theirs), Self.message("2", .mine)]) == nil)
        #expect(Chat.waitWhatID(in: []) == nil)
        #expect(Chat.waitWhatID(in: [Self.message("1", .tool(name: nil))]) == nil)
    }

    /// The agent's `wait-what` skill loads on "wait, what?" in his words; the rest asks plainly where it is not there.
    @Test func whatItSendsOpensWithTheSkillsWordsAndHisBubbleSaysOnlyThem() {
        let text = ChatQuickReply.waitWhat.text
        #expect(text.hasPrefix("Wait, what?"))
        #expect(text.contains("wait-what skill"))
        #expect(ChatQuickReply.shown(text) == "Wait, what?")
        #expect(ChatQuickReply.shown("\(text)\n") == "Wait, what?", "as the transcript keeps it")
        #expect(ChatQuickReply.shown("Wait, what? Which branch?") == "Wait, what? Which branch?", "his own words stay")
    }
}
