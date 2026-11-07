import Foundation
import PRKitCore

extension PRSession {
    static let askPollInterval: Duration = .seconds(2)

    /// The chat, about a line when there is one. Words already written go at once.
    func openAsk(about anchor: PRAskQuestion.Anchor? = nil, words: String = "") {
        askAnchor = anchor ?? askAnchor
        isShowingAsk = true
        if !words.isEmpty {
            askDraft = words
            Task { await sendAsk() }
        }
    }

    func askAnchor(for target: PRComposerTarget, code: String) -> PRAskQuestion.Anchor? {
        guard case let .line(path, line, side) = target else {
            return nil
        }
        return PRAskQuestion.Anchor(path: path, line: line, side: side.rawValue, code: String(code.prefix(500)))
    }

    /// The words leave the box at once, as a sent message, and come back to it if they can't go. The anchor goes with one
    /// question: the next is about the PR unless he picks a line.
    func sendAsk() async {
        let question = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = content?.detail.head, !question.isEmpty, !isSendingAsk else {
            return
        }
        isSendingAsk = true
        askError = nil
        askPending = question
        askDraft = ""
        defer {
            isSendingAsk = false
            askPending = nil
        }
        do {
            askChat = try await model.ask(
                PRAskQuestion(question: question, head: head, anchor: askAnchor), about: ref
            )
            askAnchor = nil
        } catch PRViewerError.saved {
            askAnchor = nil
            askError = PRViewerError.saved.localizedDescription
        } catch {
            askDraft = question
            askError = error.localizedDescription
        }
    }

    /// While the sheet shows: the conversation, every 2 seconds while the agent works, and once otherwise.
    func followAsk() async {
        while !Task.isCancelled {
            do {
                askChat = try await model.askChat(ref)
                askError = model.hasQueuedAIChat(about: ref) ? PRViewerError.saved.localizedDescription : nil
            } catch {
                askError = error.localizedDescription
            }
            guard askChat?.isWorking == true || isSendingAsk || model.hasQueuedAIChat(about: ref) else {
                return
            }
            try? await Task.sleep(for: Self.askPollInterval)
        }
    }
}
