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

    /// Where the model keeps this PR's unsent question about `askAnchor`.
    var askDraftKey: String {
        let about = askAnchor.map { "|\($0.path):\($0.line):\($0.side)" } ?? ""
        return "\(ref.repo)#\(ref.number)\(about)"
    }

    /// The question is about the whole PR from now. Its words come along: he dropped the line, not what he wrote.
    func askAboutWholePR() {
        let words = askDraft
        askDraft = ""
        askAnchor = nil
        if !words.isEmpty {
            askDraft = words
        }
    }

    /// A question's words back in the box, about what it was asked about.
    func redraft(_ words: String, about anchor: PRAskQuestion.Anchor?) {
        askAnchor = anchor ?? askAnchor
        askDraft = words
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
        // "go" under a drafted review posts it: the draft is on screen, so the word is his yes to it.
        if Self.postWords.contains(words.lowercased().trimmingCharacters(in: .punctuationCharacters)),
           let message = pendingAskReview {
            askDraft = ""
            postAskReview(message)
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
        } else if let failed = askChat?.unsentQuestion, let head = content?.detail.head {
            await send(PRAskQuestion(question: failed.text, head: head, anchor: failed.askedAbout))
        }
    }

    /// A failed question's words back in the box, to change before they go again. Sent, they take its place.
    func editFailedAsk() {
        guard let failed = askChat?.unsentQuestion else {
            return
        }
        redraft(failed.text, about: failed.askedAbout)
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

// MARK: - A review Ask drafted

extension PRSession {
    /// What, said under a drafted review, posts it.
    static let postWords: Set<String> = ["go", "post", "post it", "send", "send it", "ship it"]
    /// The answers whose drafted review he added or posted, by message id: on this device for good, so a draft is used
    /// once, whenever the chat opens again.
    private static let usedReviewsKey = "PRAskUsedReviews"
    private static let usedReviewsKept = 200

    func isUsed(_ message: PRAskChat.Message) -> Bool {
        _ = askReviewsUsed
        return UserDefaults.standard.stringArray(forKey: Self.usedReviewsKey)?.contains(message.id) ?? false
    }

    /// The newest answer, when it drafted a review not yet used: what "go" posts.
    var pendingAskReview: PRAskChat.Message? {
        guard let last = askChat?.messages.last(where: { !$0.isJai }), last.draft?.reviewEvent != nil,
              !isUsed(last) else {
            return nil
        }
        return last
    }

    /// Its line comments join his drafts, and its words wait in its review's box on the PR, to change before they go.
    func addAskReviewToDrafts(_ message: PRAskChat.Message) {
        guard let draft = message.draft, let event = draft.reviewEvent else {
            return
        }
        addDrafts(draft.draftComments)
        openText(for: .review(event)).wrappedValue = draft.body
        markUsed(message)
        isShowingAsk = false
    }

    /// Posted as Jai's review, from his account, with its line comments and any of his own drafts: the review's way
    /// (`submitReview`), so the toast follows it and a refusal puts it all back in his drafts and the box.
    func postAskReview(_ message: PRAskChat.Message) {
        guard let draft = message.draft, let event = draft.reviewEvent else {
            return
        }
        addDrafts(draft.draftComments)
        markUsed(message)
        do {
            try submitReview(draft.body, to: .review(event))
        } catch {
            askError = PRAskReadProblem(error)
        }
    }

    private func markUsed(_ message: PRAskChat.Message) {
        var used = UserDefaults.standard.stringArray(forKey: Self.usedReviewsKey) ?? []
        used.append(message.id)
        UserDefaults.standard.set(Array(used.suffix(Self.usedReviewsKept)), forKey: Self.usedReviewsKey)
        askReviewsUsed += 1
    }
}

extension PRAskChat {
    /// The last question when it got no answer: one the Worker could not hand to the agent (`ask-queue.ts`), or a turn
    /// that failed (`ask-subscription.ts`). Retry sends its words again, and the Worker puts them in its place.
    var unsentQuestion: Message? {
        guard !isWorking, problem != nil, let last = messages.last, last.isJai else {
            return nil
        }
        return last
    }
}

extension PRAskChat.Message {
    /// The line a question was about, from its `path:line` and side, so a Retry asks about the same line.
    var askedAbout: PRAskQuestion.Anchor? {
        guard let anchor, let colon = anchor.lastIndex(of: ":"),
              let line = Int(anchor[anchor.index(after: colon)...]) else {
            return nil
        }
        return PRAskQuestion.Anchor(path: String(anchor[..<colon]), line: line, side: side ?? PRDiffSide.right.rawValue)
    }
}
