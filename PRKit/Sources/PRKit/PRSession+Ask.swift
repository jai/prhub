import Foundation
import PRKitCore
import PRKitDesign
import SwiftUI

extension PRSession {
    static let askPollInterval: Duration = .seconds(2)
    /// The longest wait between reads that keep failing: offline, a read every 2 seconds would keep the radio up.
    static let askPollLongest: Duration = .seconds(30)

    /// The wait before the next read: 2 seconds, doubled for each read in a row that failed, at most 30.
    static func askPollWait(afterFailures failures: Int) -> Duration {
        min(askPollInterval * (1 << min(failures, 5)), askPollLongest)
    }

    /// The chat, about a line when there is one. Words already written go at once, as asked from `origin`.
    func openAsk(about anchor: PRAskQuestion.Anchor? = nil, words: String = "", origin: PRAskOrigin? = nil) {
        askAnchor = anchor ?? askAnchor
        isShowingAsk = true
        if !words.isEmpty {
            askDraft = words
            Task { await sendAsk(origin: origin) }
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
        openAsk(
            about: anchor, words: "Explain this line. It was picked as a key line: \(item.why)", origin: .explainLine
        )
    }

    /// The chat about the whole PR, asked to sum it up and explain it: the description's ? button.
    func explainPR() {
        askAnchor = nil
        openAsk(
            words: "Summarize this PR and explain it in plain words: what it changes, why, and how it works. "
                + "Then say what a reviewer should look at closely.",
            origin: .explainPR
        )
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
    /// unless he picks a line. `origin` is what asked it; nil is words he typed.
    func sendAsk(origin: PRAskOrigin? = nil) async {
        let words = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = content?.detail.head, !words.isEmpty, !isSendingAsk else {
            return
        }
        // "go" under a drafted review, or a proposed Linear comment, posts it: it is on screen, so the word is his yes.
        if Self.postWords.contains(words.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            if let message = pendingAskReview {
                askDraft = ""
                postAskReview(message)
                return
            }
            if let (message, index) = pendingAskLinear {
                askDraft = ""
                await postAskLinear(message, index: index)
                return
            }
        }
        askDraft = ""
        let question = PRAskQuestion(question: words, head: head, anchor: askAnchor)
        let origin = origin ?? (askAnchor == nil ? .typed : .typedLine)
        askAnchor = nil
        await send(question, origin: origin)
    }

    /// A question that could not go, sent again: from the phone, or one the Worker could not hand to the agent.
    func retryAsk() async {
        if case let .failed(question, _) = askSend {
            await send(question, origin: .retry)
        } else if let failed = askChat?.unsentQuestion, let head = content?.detail.head {
            await send(PRAskQuestion(question: failed.text, head: head, anchor: failed.askedAbout), origin: .retry)
        }
    }

    /// A failed question's words back in the box, to change before they go again. Sent, they take its place.
    func editFailedAsk() {
        guard let failed = askChat?.unsentQuestion else {
            return
        }
        redraft(failed.text, about: failed.askedAbout)
    }

    /// How it went goes to the host (`PRKitEvent.askSent`).
    private func send(_ question: PRAskQuestion, origin: PRAskOrigin) async {
        guard !isSendingAsk else {
            return
        }
        isSendingAsk = true
        askError = nil
        withAnimation(AppMotion.swap) { askSend = .sending(question) }
        defer { isSendingAsk = false }
        let outcome: Result<PRAskOutcome, any Error>
        do {
            outcome = try .success(await model.ask(question, about: ref))
        } catch {
            outcome = .failure(error)
        }
        withAnimation(AppMotion.swap) {
            if case let .success(.answered(chat)) = outcome {
                askChat = chat
            }
            askSend = .after(outcome, of: question, isOnline: model.isOnline())
        }
        let told: PRActionOutcome? = switch outcome {
        case .success(.answered): .done
        case .success(.queued): .queued
        case let .failure(error): PRActionOutcome(error: error)
        }
        if let told {
            model.onEvent(.askSent(origin, told))
        }
        if case let .success(.answered(chat)) = outcome {
            reportAnswerFailure(in: chat)
        }
    }

    /// A question the Worker could not hand to the agent, or whose turn failed (`PRAskChat.unsentQuestion`): told once
    /// for each such question, however often the chat is read.
    func reportAnswerFailure(in chat: PRAskChat) {
        guard let failed = chat.unsentQuestion, failed.id != reportedAskFailure else {
            return
        }
        reportedAskFailure = failed.id
        model.onEvent(.askAnswerFailed)
    }

    /// While the sheet shows: the conversation, every 2 seconds while the agent works or a question is on its way, and
    /// once otherwise; a read that keeps failing is tried less often (`askPollWait`). A question in the outbox is on its
    /// way, not an error.
    func followAsk() async {
        var failures = 0
        // The chat as last read shows at once; the Worker's answer replaces it.
        if askChat == nil {
            askChat = model.keptAskChat(ref)
        }
        while !Task.isCancelled {
            do {
                let chat = try await model.askChat(ref)
                withAnimation(AppMotion.swap) {
                    askChat = chat
                    askError = nil
                }
                reportAnswerFailure(in: chat)
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
            failures = askError == nil ? 0 : failures + 1
            try? await Task.sleep(for: Self.askPollWait(afterFailures: failures))
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
              !isUsed(last)
        else {
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
        model.onEvent(.askReviewUsed(.addedToDrafts))
    }

    /// Posted as Jai's review, from his account, with its line comments and any of his own drafts: the review's way
    /// (`submitReview`), so the toast follows it and a refusal puts it all back in his drafts and the box.
    func postAskReview(_ message: PRAskChat.Message) {
        guard let draft = message.draft, let event = draft.reviewEvent else {
            return
        }
        addDrafts(draft.draftComments)
        markUsed(message)
        model.onEvent(.askReviewUsed(.posted))
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

// MARK: - A Linear comment Ask proposed

extension PRSession {
    /// One card's name: its answer, then its place under it.
    static func askLinearKey(_ message: PRAskChat.Message, _ index: Int) -> String {
        "\(message.id):\(index)"
    }

    /// The newest answer's one Linear comment that can post: what "go" posts. Nil with none, or more than one.
    var pendingAskLinear: (PRAskChat.Message, Int)? {
        guard let last = askChat?.messages.last(where: { !$0.isJai }), let cards = last.linear else {
            return nil
        }
        let ready = cards.indices.filter { cards[$0].canPost && cards[$0].state == .proposed }
        return ready.count == 1 ? (last, ready[0]) : nil
    }

    /// Posted as Jai with his Linear key, by the Worker, once. The chat comes back with the card posted, or failed with
    /// Linear's reason and a Retry.
    func postAskLinear(_ message: PRAskChat.Message, index: Int) async {
        let key = Self.askLinearKey(message, index)
        guard !askLinearPosting.contains(key) else {
            return
        }
        askLinearPosting.insert(key)
        askLinearProblems[key] = nil
        defer { askLinearPosting.remove(key) }
        do {
            let chat = try await model.postAskLinear(message: message.id, index: index, about: ref)
            withAnimation(AppMotion.swap) { askChat = chat }
            // Linear's refusal comes back on the card, in Linear's words.
            let card = chat.messages.first { $0.id == message.id }?.linear.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            model.onEvent(.askLinearPosted(card?.state == .failed ? .failed(.refused) : .done))
        } catch {
            withAnimation(AppMotion.swap) { askLinearProblems[key] = error.localizedDescription }
            if let outcome = PRActionOutcome(error: error) {
                model.onEvent(.askLinearPosted(outcome))
            }
        }
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
              let line = Int(anchor[anchor.index(after: colon)...])
        else {
            return nil
        }
        return PRAskQuestion.Anchor(path: String(anchor[..<colon]), line: line, side: side ?? PRDiffSide.right.rawValue)
    }
}
