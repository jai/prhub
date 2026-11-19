import Foundation
import PRKitCore

/// What goes through the host's outbox (`PRKitOutbox`): writes and questions, each in its own job, answer and words.
extension PRsModel {
    /// The Worker's chat with the question in it, or `.queued` when the host's outbox holds it past `answerWait`: it
    /// goes on sending it, and the sheet follows it there.
    func ask(_ question: PRAskQuestion, about ref: PullRequestRef) async throws -> PRAskOutcome {
        guard let outbox else {
            return try .answered(await client.ask(question, about: ref))
        }
        let job = PROutboxJob.question(question, ref: ref)
        let id = try await enqueue(job, using: outbox)
        switch try await answer(to: id) {
        case let .answered(data): return try .answered(JSONDecoder().decode(PRAskChat.self, from: data))
        case .stillGoing: return .queued
        }
    }

    func hasQueuedQuestion(about ref: PullRequestRef) -> Bool {
        outbox?.isQueued(.question, about: ref) ?? false
    }

    /// Posts as Jai: the PR as it now stands, or the write saved on the phone and still going. The mirror follows on
    /// its own, soon after. How it went goes to the host (`PRKitEvent.wrote`); a refusal after the screen has gone is
    /// `writeRefused`.
    /// `queued` hears the outbox's id for it, when it is saved there.
    func write(
        _ write: PRWrite, to ref: PullRequestRef, queued: (String) -> Void = { _ in }
    ) async throws -> PRWriteOutcome {
        do {
            let outcome = try await post(write, to: ref, queued: queued)
            onEvent(.wrote(PRWriteKind(write), PRActionOutcome(outcome)))
            return outcome
        } catch {
            if let outcome = PRActionOutcome(error: error) {
                onEvent(.wrote(PRWriteKind(write), outcome))
            }
            throw error
        }
    }

    private func post(
        _ write: PRWrite, to ref: PullRequestRef, queued: (String) -> Void
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

    /// What `write` makes of a sample PR, kept in its file so the PR shows it when it opens again, and in its row so
    /// the list does. Nil for a PR that is not a sample.
    private func sampleWrite(_ write: PRWrite, to ref: PullRequestRef) -> PullRequestDetail? {
        let isThisPR = { (row: PullRequestRow) in row.repo == ref.repo && row.number == ref.number }
        guard let row = rows.first(where: isThisPR) ?? merged.values.joined().first(where: isThisPR),
              let stored = mirror.files.read(row.detailFileName)
        else {
            return nil
        }
        let login = configuration.login ?? "you"
        let data = PRSampleSet.applying(write, to: stored, login: login)
        try? mirror.files.write(data, to: row.detailFileName)
        sampleWritten(write, to: row)
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
            return try .posted(PullRequestDetail.decode(await client.write(write, to: ref)))
        }
        let job = PROutboxJob.write(write, ref: ref)
        let id = try await enqueue(job, using: outbox)
        saved(id)
        switch try await answer(to: id) {
        case let .answered(data): return try .posted(PullRequestDetail.decode(data))
        case .stillGoing: return .queued(isOnline() ? .sending : .waitingForNetwork)
        }
    }

    private func enqueue(_ job: PROutboxJob, using outbox: any PRKitOutbox) async throws -> String {
        enqueuesInFlight += 1
        defer {
            enqueuesInFlight -= 1
            if enqueuesInFlight == 0 {
                let unmatched = earlyOutboxDeliveries
                earlyOutboxDeliveries.removeAll()
                for delivery in unmatched {
                    deliver(delivery)
                }
            }
        }
        let id = try await outbox.enqueue(job)
        queued[id] = job
        waiting.insert(id)
        let arrived = earlyOutboxDeliveries.filter { $0.id == id }
        earlyOutboxDeliveries.removeAll { $0.id == id }
        for delivery in arrived {
            deliver(delivery)
        }
        return id
    }

    private func keepEarly(_ delivery: PROutboxDelivery) -> Bool {
        guard enqueuesInFlight > 0, !waiting.contains(delivery.id), queued[delivery.id] == nil else {
            return false
        }
        earlyOutboxDeliveries.append(delivery)
        return true
    }

    private func deliver(_ delivery: PROutboxDelivery) {
        switch delivery {
        case let .answered(id, data): outboxAnswered(id: id, data: data)
        case let .refused(id, kind, reason): outboxRefused(id: id, kind: kind, reason: reason)
        }
    }

    /// The outbox's answer if it comes within `answerWait`; else the job goes on without the screen. A refusal in time
    /// is thrown. The screen sleeps until the answer, the end of the wait on the model's clock, or its cancellation,
    /// whichever comes first.
    private func answer(to id: String) async throws -> PROutboxAnswer {
        defer { waiting.remove(id) }
        if outcomes[id] == nil, !Task.isCancelled {
            let (wait, sleep) = (answerWait, sleep)
            // Cancelled once the screen has woken, when waking it again does nothing.
            let timer = Task { [weak self] in
                try? await sleep(wait)
                self?.wakeAnswerWait(id)
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { answerWaits[id] = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.wakeAnswerWait(id) }
            }
            timer.cancel()
        }
        // Looked for before cancellation is: an answer that came with the end of the wait or the cancellation would
        // otherwise be held and lost.
        if let outcome = outcomes.removeValue(forKey: id) {
            queued[id] = nil
            return try .answered(outcome.get())
        }
        try Task.checkCancellation()
        return .stillGoing
    }

    private func wakeAnswerWait(_ id: String) {
        answerWaits.removeValue(forKey: id)?.resume()
    }

    /// The Worker's answer to an outbox item, for the screen waiting on it.
    func outboxAnswered(id: String, data: Data) {
        if keepEarly(.answered(id: id, data: data)) {
            return
        }
        guard waiting.contains(id) else {
            queued[id] = nil
            _ = reviewLanded(job: id, data: data)
            return
        }
        outcomes[id] = .success(data)
        wakeAnswerWait(id)
    }

    /// A refusal in time is the screen's to show. A later one would otherwise be lost: it says what the job was, in
    /// its kind's words.
    func outboxRefused(id: String, kind: PROutboxJob.Kind, reason why: String) {
        if keepEarly(.refused(id: id, kind: kind, reason: why)) {
            return
        }
        if waiting.contains(id) {
            outcomes[id] = .failure(.refused(why))
            wakeAnswerWait(id)
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

/// Held only while enqueue calls can still return an unknown ID; unmatched restored jobs are replayed afterward.
enum PROutboxDelivery {
    case answered(id: String, data: Data)
    case refused(id: String, kind: PROutboxJob.Kind, reason: String)

    var id: String {
        switch self {
        case let .answered(id, _), let .refused(id, _, _): id
        }
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
