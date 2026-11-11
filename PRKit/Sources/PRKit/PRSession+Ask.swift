import Foundation
import PRKitCore
import PRKitDesign
import SwiftUI

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

    /// The chat about a key line, asked to explain it, with its code and why it was picked.
    func explain(_ item: PRKeyLines.Item, in document: DiffDocument) {
        let isOld = item.side == PRDiffSide.left.rawValue
        let line = document.lines.first {
            document.files[$0.file] == item.path && (isOld ? $0.oldLine : $0.newLine) == item.line
                && (isOld ? $0.kind != .added : $0.kind != .removed)
        }
        let code = line.map { String(document.text(of: $0).dropFirst().prefix(500)) }
        let anchor = PRAskQuestion.Anchor(path: item.path, line: item.line, side: item.side, code: code)
        openAsk(about: anchor, words: "Explain this line. It was picked as a key line: \(item.why)")
    }

    func askAnchor(for target: PRComposerTarget, code: String) -> PRAskQuestion.Anchor? {
        guard case let .line(path, line, side) = target else {
            return nil
        }
        return PRAskQuestion.Anchor(path: path, line: line, side: side.rawValue, code: String(code.prefix(500)))
    }

    /// The words leave the box at once, as a sent message. The anchor goes with one question: the next is about the PR
    /// unless he picks a line.
    func sendAsk() async {
        let words = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = content?.detail.head, !words.isEmpty, !isSendingAsk else {
            return
        }
        askDraft = ""
        let question = PRAskQuestion(question: words, head: head, anchor: askAnchor)
        askAnchor = nil
        await send(question)
    }

    /// A question that could not go, sent again: from the phone, or one the Worker could not hand to the agent.
    func retryAsk() async {
        if case let .failed(question, _) = askSend {
            await send(question)
        } else if let words = askChat?.unsentQuestion, let head = content?.detail.head {
            await send(PRAskQuestion(question: words, head: head, anchor: nil))
        }
    }

    private func send(_ question: PRAskQuestion) async {
        guard !isSendingAsk else {
            return
        }
        isSendingAsk = true
        askError = nil
        withAnimation(AppMotion.swap) { askSend = .sending(question) }
        defer { isSendingAsk = false }
        let outcome: Result<PRAskOutcome, any Error>
        do {
            outcome = .success(try await model.ask(question, about: ref))
        } catch {
            outcome = .failure(error)
        }
        withAnimation(AppMotion.swap) {
            if case let .success(.answered(chat)) = outcome {
                askChat = chat
            }
            askSend = .after(outcome, of: question, isOnline: model.isOnline())
        }
    }

    /// While the sheet shows: the conversation, every 2 seconds while the agent works or a question is on its way, and
    /// once otherwise. A question in the outbox is on its way, not an error.
    func followAsk() async {
        while !Task.isCancelled {
            do {
                let chat = try await model.askChat(ref)
                withAnimation(AppMotion.swap) {
                    askChat = chat
                    askError = nil
                }
            } catch {
                withAnimation(AppMotion.swap) { askError = PRAskReadProblem(error) }
            }
            if !isSendingAsk {
                let next = askSend.following(isQueued: model.hasQueuedQuestion(about: ref), isOnline: model.isOnline())
                if next != askSend {
                    withAnimation(AppMotion.swap) { askSend = next }
                }
            }
            // A failed read is read again: the chat shows once the Worker answers.
            guard askChat?.isWorking == true || isSendingAsk || askSend.isOnItsWay || askError != nil else {
                return
            }
            try? await Task.sleep(for: Self.askPollInterval)
        }
    }
}

extension PRAskChat {
    /// The question the Worker kept but could not hand to the agent (`worker/src/ask-queue.ts`), for Try again.
    var unsentQuestion: String? {
        guard !isWorking, problem != nil, let last = messages.last, last.isJai, last.id.hasPrefix("queued:") else {
            return nil
        }
        return last.text
    }
}
