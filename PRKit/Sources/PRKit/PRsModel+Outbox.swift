import Foundation
import PRKitCore

/// What goes through the host's outbox (`PRKitOutbox`): writes and questions, each in its own job, answer and words.
extension PRsModel {
    /// The Worker's chat with the question in it, or `.queued` when the host's outbox holds it past `answerWait`: it
    /// goes on sending it, and the sheet follows it there.
    func ask(_ question: PRAskQuestion, about ref: PullRequestRef) async throws -> PRAskOutcome {
        guard let outbox else {
            return .answered(try await client.ask(question, about: ref))
        }
        let job = PROutboxJob.question(question, ref: ref)
        let id = try await outbox.enqueue(job)
        queued[id] = job
        switch try await answer(to: id) {
        case let .answered(data): return .answered(try JSONDecoder().decode(PRAskChat.self, from: data))
        case .stillGoing: return .queued
        }
    }

    func hasQueuedQuestion(about ref: PullRequestRef) -> Bool {
        outbox?.isQueued(.question, about: ref) ?? false
    }

    /// Posts as Jai: the PR as it now stands, or the write saved on the phone and still going. The mirror follows on
    /// its own, soon after.
    /// `queued` hears the outbox's id for it, when it is saved there.
    func write(
        _ write: PRWrite, to ref: PullRequestRef, queued: (String) -> Void = { _ in }
    ) async throws -> PRWriteOutcome {
        // A sample row can name a real PR. Nothing done to it may reach GitHub.
        if let samples {
            guard samples.answersOnPhone, let detail = sampleWrite(write, to: ref) else {
                throw PRLocalRefusal.sampleWrite
            }
            return .posted(detail)
        }
        let outcome = try await send(write, to: ref, queued: queued)
        if case .posted = outcome {
            Task { await refresh(.pull) }
        }
        return outcome
    }

    /// What `write` makes of a sample PR, kept in its file so the PR shows it when it opens again. Nil for a PR that
    /// is not a sample.
    private func sampleWrite(_ write: PRWrite, to ref: PullRequestRef) -> PullRequestDetail? {
        guard let row = rows.first(where: { $0.repo == ref.repo && $0.number == ref.number }) else {
            return nil
        }
        let file = mirror.directory.appending(path: row.detailFileName)
        guard let stored = try? Data(contentsOf: file) else {
            return nil
        }
        let login = configuration.login ?? "you"
        let data = PRSampleSet.applying(write, to: stored, login: login)
        try? data.write(to: file)
        return try? PullRequestDetail.decode(data)
    }

    /// Said under a PR's actions after a write: that a sample's went nowhere. Nil for real PRs.
    var writeNotice: PRNotice? {
        samples?.answersOnPhone == true ? .sampleOnly : nil
    }

    /// Merge and update branch go now or not at all: Jai should see them happen. The rest are saved first.
    private func send(
        _ write: PRWrite, to ref: PullRequestRef, queued saved: (String) -> Void
    ) async throws -> PRWriteOutcome {
        guard let outbox, write.isQueued else {
            return .posted(try PullRequestDetail.decode(await client.write(write, to: ref)))
        }
        let job = PROutboxJob.write(write, ref: ref)
        let id = try await outbox.enqueue(job)
        queued[id] = job
        saved(id)
        switch try await answer(to: id) {
        case let .answered(data): return .posted(try PullRequestDetail.decode(data))
        case .stillGoing: return .queued(isOnline() ? .sending : .waitingForNetwork)
        }
    }

    /// The outbox's answer if it comes within `answerWait`; else the job goes on without the screen. A refusal in time
    /// is thrown.
    private func answer(to id: String) async throws -> PROutboxAnswer {
        waiting.insert(id)
        defer { waiting.remove(id) }
        let clock = ContinuousClock()
        let end = clock.now + answerWait
        // Looked for once more after the last wait: an answer that came during it would otherwise be held and lost.
        while true {
            if let outcome = outcomes.removeValue(forKey: id) {
                queued[id] = nil
                return .answered(try outcome.get())
            }
            guard clock.now < end else {
                return .stillGoing
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The Worker's answer to an outbox item, for the screen waiting on it.
    func outboxAnswered(id: String, data: Data) {
        guard waiting.contains(id) else {
            queued[id] = nil
            _ = reviewLanded(job: id, data: data)
            return
        }
        outcomes[id] = .success(data)
    }

    /// A refusal in time is the screen's to show. A later one would otherwise be lost: it says what the job was, in
    /// its kind's words.
    func outboxRefused(id: String, kind: PROutboxJob.Kind, reason why: String) {
        if waiting.contains(id) {
            outcomes[id] = .failure(.refused(why))
            return
        }
        if case let .write(write, ref) = queued[id], reviewRefused(job: id, reason: why) {
            queued[id] = nil
            onEvent(.writeRefused(write.refusal(on: ref, reason: why)))
            return
        }
        let words = switch queued.removeValue(forKey: id) {
        case let .write(write, ref): write.refusal(on: ref, reason: why)
        case let .question(question, ref): question.refusal(on: ref, reason: why)
        case nil: kind.refusal(reason: why)
        }
        refuseLate(words, of: kind)
    }

    func refuseLate(_ words: String, of kind: PROutboxJob.Kind) {
        lateRefusal = words
        onEvent(kind == .write ? .writeRefused(words) : .questionRefused(words))
    }

    func dismissLateRefusal() {
        lateRefusal = nil
    }
}

private extension PRWrite {
    var isQueued: Bool {
        switch self {
        case .merge, .updateBranch: false
        default: true
        }
    }
}

/// What the outbox said within `answerWait`.
private enum PROutboxAnswer {
    case answered(Data)
    /// No answer yet: the outbox goes on sending it.
    case stillGoing
}
