import AgentChatKit
import PRKitCore

/// What Ask's sheet shows of the chat: its messages, whether the agent is at work, and how far each question got.
extension PRSession {
    /// The chat's, then the question on its way, until the chat has it.
    var askMessages: [PRAskChat.Message] {
        let sent = askChat?.messages ?? []
        guard let question = askSend.question, sent.last(where: \.isJai)?.text != question.question else {
            return sent
        }
        let anchor = question.anchor.map { "\($0.path):\($0.line)" }
        return sent + [PRAskChat.Message(id: "pending", role: "you", text: question.question, anchor: anchor)]
    }

    /// The agent at work on a question it has. A question still on its way says so instead.
    var isAskWorking: Bool {
        askSend == .idle && askChat?.isWorking == true
    }

    /// How far his question at `index` of `askMessages` got: one tick once the Worker has it, two once the agent has
    /// it, as working on it or answering it shows. None while it is on its way, or when it could not reach the agent.
    func askTicks(at index: Int) -> DeliveryTicks? {
        let messages = askMessages
        let message = messages[index]
        guard message.isJai, message.id != "pending" else {
            return nil
        }
        if messages[(index + 1)...].contains(where: { !$0.isJai }) {
            return .delivered
        }
        guard index == messages.count - 1, askSend == .idle, askChat?.unsentQuestion == nil else {
            return nil
        }
        return isAskWorking ? .delivered : .sent
    }
}
