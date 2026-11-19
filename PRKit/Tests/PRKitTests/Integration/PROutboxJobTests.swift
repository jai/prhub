import DurableNetworking
import Foundation
@testable import PRKit
import Testing

/// Each kind of outbox job in its own states and words: one delivery, never one meaning.
@MainActor
struct PROutboxJobTests {
    /// An outbox that keeps every job until the test answers or refuses it.
    @MainActor
    final class Outbox: PRKitOutbox {
        private(set) var jobs: [(id: String, job: PROutboxJob)] = []
        var onEnqueue: ((String) -> Void)?
        var beforeReturn: ((String) async throws -> Void)?

        func enqueue(_ job: PROutboxJob) async throws -> String {
            let id = "job-\(jobs.count + 1)"
            jobs.append((id, job))
            onEnqueue?(id)
            do {
                try await beforeReturn?(id)
            } catch {
                jobs.removeAll { $0.id == id }
                throw error
            }
            return id
        }

        func isQueued(_ kind: PROutboxJob.Kind, about ref: PullRequestRef) -> Bool {
            jobs.contains { $0.job.kind == kind && $0.job.ref == ref }
        }
    }

    @MainActor
    final class Host: PRKitHost {
        let storage = TestStorage()
        var mirrorDirectory: URL? {
            storage.directory
        }

        let access = PRViewerAccess.offline
        let configuration = PRKitConfiguration.everything
        let held = Outbox()
        var outbox: (any PRKitOutbox)? {
            held
        }

        let apnsEnvironment = "sandbox"
        let samples: PRSampleSet? = nil
        let launchOptions = PRKitLaunchOptions.none
        private(set) var events: [PRKitEvent] = []

        let transport: any HTTPTransport = UnexpectedTransport()
        func log(_: String) {}
        func receive(_ event: PRKitEvent) {
            events.append(event)
        }
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    /// The model's clock: the answer wait ends only when a test moves it on.
    private let clock = TestClock()
    private static let detail = Data("""
    {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
    "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
    "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
    """.utf8)

    private func kit(wait: Duration = .seconds(15), isOnline: Bool = true) -> (PRKitController, Host) {
        let host = Host()
        let kit = PRKitController(host: host, defaults: host.storage.defaults, network: PRNetwork(isOnline: true),
                                  draftDirectory: host.storage.draftDirectory)
        kit.model.answerWait = wait
        let clock = clock
        kit.model.sleep = { try await clock.sleep(for: $0) }
        kit.model.isOnline = { isOnline }
        return (kit, host)
    }

    /// What `send` comes to when no answer comes within the answer wait.
    private func pastTheWait<T: Sendable>(
        _ kit: PRKitController, _ send: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let sending = Task { try await send() }
        try await clock.advance(by: kit.model.answerWait, afterSleepers: 1)
        return try await sending.value
    }

    private func firstJob(_ kit: PRKitController, _ host: Host) async throws -> String {
        try await waitUntil("outbox job registered as waiting") { !kit.model.waiting.isEmpty }
        return try #require(host.held.jobs.first?.id)
    }

    @Test func aWriteAnsweredInTimeIsPosted() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        try kit.outboxAnswered(id: await firstJob(kit, host), data: Self.detail)
        let outcome = try await sent.value
        #expect(outcome.posted?.mergeState == "CLEAN")
        guard case .write(.comment("Ship it."), ref) = host.held.jobs[0].job else {
            Issue.record("a comment goes as a write job")
            return
        }
    }

    @Test func anAnswerDeliveredBeforeEnqueueReturnsCompletesTheWrite() async throws {
        let (kit, host) = kit(wait: .zero)
        host.held.onEnqueue = { [weak kit] id in kit?.outboxAnswered(id: id, data: Self.detail) }
        let outcome = try await kit.model.write(.comment(body: "Ship it."), to: ref)
        #expect(outcome.posted?.mergeState == "CLEAN")
        #expect(host.events == [.wrote(.comment, .done)])
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test func aRefusalDeliveredBeforeEnqueueReturnsFailsTheWrite() async {
        let (kit, host) = kit(wait: .zero)
        host.held.onEnqueue = { [weak kit] id in
            kit?.outboxRefused(id: id, kind: .write, reason: "Pull request is locked")
        }
        await #expect(throws: PRWorkerError.refused("Pull request is locked")) {
            try await kit.model.write(.comment(body: "Ship it."), to: ref)
        }
        #expect(kit.model.lateRefusal == nil)
        #expect(host.events == [.wrote(.comment, .failed(.refused))])
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test func anAnswerDeliveredBeforeEnqueueReturnsCompletesTheQuestion() async throws {
        let (kit, host) = kit(wait: .zero)
        let data = Data(#"{"messages":[{"id":"answer","role":"agent","text":"It is tested."}],"isWorking":false}"#.utf8)
        let chat = try JSONDecoder().decode(PRAskChat.self, from: data)
        host.held.onEnqueue = { [weak kit] id in kit?.outboxAnswered(id: id, data: data) }
        let question = PRAskQuestion(question: "Is it tested?", head: "head", anchor: nil)
        #expect(try await kit.model.ask(question, about: ref) == .answered(chat))
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test func aRefusalDeliveredBeforeEnqueueReturnsFailsTheQuestion() async {
        let (kit, host) = kit(wait: .zero)
        host.held.onEnqueue = { [weak kit] id in
            kit?.outboxRefused(id: id, kind: .question, reason: "Spending limit reached")
        }
        let question = PRAskQuestion(question: "Is it tested?", head: "head", anchor: nil)
        await #expect(throws: PRWorkerError.refused("Spending limit reached")) {
            try await kit.model.ask(question, about: ref)
        }
        #expect(kit.model.lateRefusal == nil)
        #expect(host.events.isEmpty)
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test func restoredCallbacksDuringEnqueueKeepTheirNormalLateHandling() async throws {
        let (kit, host) = kit(wait: .zero)
        host.held.onEnqueue = { [weak kit] id in
            kit?.outboxAnswered(id: "restored-answer", data: Self.detail)
            kit?.outboxRefused(id: "restored-first", kind: .question, reason: "First restored refusal")
            kit?.outboxRefused(id: "restored-refusal", kind: .question, reason: "Restored refusal")
            kit?.outboxAnswered(id: id, data: Self.detail)
        }
        #expect(try await kit.model.write(.comment(body: "New comment"), to: ref).posted != nil)
        let words = "A question to a PR's AI couldn't be sent: Restored refusal"
        #expect(kit.model.lateRefusal == words)
        #expect(host.events == [
            .questionRefused("A question to a PR's AI couldn't be sent: First restored refusal"),
            .questionRefused(words), .wrote(.comment, .done),
        ])
        #expect(kit.model.enqueuesInFlight == 0 && kit.model.earlyOutboxDeliveries.isEmpty)
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func overlappingEnqueuesClaimOnlyTheirOwnEarlyAnswers() async throws {
        let (kit, host) = kit(wait: .zero)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        host.held.onEnqueue = { [weak kit] id in kit?.outboxAnswered(id: id, data: Self.detail) }
        host.held.beforeReturn = { id in
            if id == "job-1" {
                entered.continuation.yield(())
                for await _ in release.stream {
                    break
                }
            }
        }
        let first = Task { try await kit.model.write(.comment(body: "First"), to: ref) }
        defer {
            first.cancel()
            entered.continuation.finish()
            release.continuation.finish()
        }
        for await _ in entered.stream {
            break
        }
        #expect(try await kit.model.write(.comment(body: "Second"), to: ref).posted != nil)
        #expect(kit.model.enqueuesInFlight == 1)
        #expect(kit.model.earlyOutboxDeliveries.map(\.id) == ["job-1"])
        release.continuation.yield(())
        #expect(try await first.value.posted != nil)
        #expect(host.events == [.wrote(.comment, .done), .wrote(.comment, .done)])
        #expect(kit.model.enqueuesInFlight == 0 && kit.model.earlyOutboxDeliveries.isEmpty)
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aKnownLateRefusalIsNotDelayedByAnotherEnqueue() async throws {
        let (kit, host) = kit(wait: .zero)
        _ = try await kit.model.write(.comment(body: "Earlier comment"), to: ref)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        host.held.onEnqueue = { [weak kit] id in
            kit?.outboxRefused(id: "job-1", kind: .write, reason: "Locked")
            kit?.outboxAnswered(id: id, data: Self.detail)
        }
        host.held.beforeReturn = { _ in
            entered.continuation.yield(())
            for await _ in release.stream {
                break
            }
        }
        let sent = Task { try await kit.model.write(.comment(body: "New comment"), to: ref) }
        defer {
            sent.cancel()
            entered.continuation.finish()
            release.continuation.finish()
        }
        for await _ in entered.stream {
            break
        }
        let words = "GitHub refused your comment “Earlier comment” on acme/api#7: Locked"
        #expect(kit.model.enqueuesInFlight == 1)
        #expect(kit.model.lateRefusal == words && host.events.last == .writeRefused(words))
        release.continuation.yield(())
        #expect(try await sent.value.posted != nil)
        #expect(kit.model.enqueuesInFlight == 0 && kit.model.earlyOutboxDeliveries.isEmpty)
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test func failedEnqueueFlushesRestoredCallbacksAndKeepsNoRegistration() async {
        let (kit, host) = kit(wait: .zero)
        host.held.onEnqueue = { [weak kit] _ in
            kit?.outboxAnswered(id: "restored-answer", data: Self.detail)
            kit?.outboxRefused(id: "restored-refusal", kind: .question, reason: "Restored refusal")
        }
        host.held.beforeReturn = { _ in throw EnqueueFailure.stopped }
        await #expect(throws: EnqueueFailure.stopped) {
            try await kit.model.write(.comment(body: "Not saved"), to: ref)
        }
        #expect(kit.model.lateRefusal == "A question to a PR's AI couldn't be sent: Restored refusal")
        let refusals = host.events.filter {
            if case .questionRefused = $0 {
                true
            } else {
                false
            }
        }
        #expect(refusals == [.questionRefused("A question to a PR's AI couldn't be sent: Restored refusal")])
        #expect(host.held.jobs.isEmpty)
        #expect(kit.model.enqueuesInFlight == 0 && kit.model.earlyOutboxDeliveries.isEmpty)
        #expect(kit.model.queued.isEmpty && kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDuringEnqueueKeepsTheSavedJobAndClearsRegistration() async throws {
        let (kit, host) = kit(wait: .zero)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        host.held.beforeReturn = { _ in
            entered.continuation.yield(())
            for await _ in release.stream {
                break
            }
        }
        let sent = Task { try await kit.model.write(.comment(body: "Still saved"), to: ref) }
        defer {
            sent.cancel()
            entered.continuation.finish()
            release.continuation.finish()
        }
        for await _ in entered.stream {
            break
        }
        sent.cancel()
        await #expect(throws: CancellationError.self) { try await sent.value }
        #expect(host.held.jobs.count == 1 && kit.model.queued["job-1"]?.kind == .write)
        #expect(kit.model.enqueuesInFlight == 0 && kit.model.earlyOutboxDeliveries.isEmpty)
        #expect(kit.model.waiting.isEmpty && kit.model.outcomes.isEmpty)
        #expect(host.events.isEmpty)
    }

    private enum EnqueueFailure: Error, Equatable { case stopped }

    @Test func eachWriteTellsTheHostWhatItDidAndHowItWent() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let merge = Task { try await kit.model.write(.merge(method: "squash", commit: "c"), to: ref) }
        await #expect(throws: (any Error).self) { try await merge.value }
        let approve = Task { try await kit.model.write(.review(.approve, body: "", commit: "c", comments: []), to: ref) }
        try kit.outboxAnswered(id: await firstJob(kit, host), data: Self.detail)
        _ = try await approve.value
        #expect(host.events == [.wrote(.merge, .failed(.local)), .wrote(.approve, .done)])
    }

    @Test func aSlowWriteOnlineIsSendingAndSaysSoInTheWaitingTone() async throws {
        let (kit, _) = kit()
        let ref = ref
        let outcome = try await pastTheWait(kit) { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        guard case .queued(.sending) = outcome else {
            Issue.record("expected sending, got \(outcome)")
            return
        }
        let session = kit.model.session(for: ref)
        let thread = try Self.thread()
        try await pastTheWait(kit) { try await session.setResolved(true, thread: thread) }
        #expect(session.notice == .queued(noun: "Resolving the thread", .sending))
        #expect(session.notice?.tone == .toneWaiting)
    }

    @Test func aWriteOfflineWaitsForTheNetwork() async throws {
        let (kit, _) = kit(isOnline: false)
        let ref = ref
        let outcome = try await pastTheWait(kit) {
            try await kit.model.write(.review(.approve, body: "", commit: "c", comments: []), to: ref)
        }
        guard case .queued(.waitingForNetwork) = outcome else {
            Issue.record("expected waiting for the network, got \(outcome)")
            return
        }
        #expect(PRNotice.queued(noun: "Your review", .waitingForNetwork).words.contains("back online"))
    }

    @Test func aRefusalInTimeIsThrownInGitHubsWords() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        try kit.outboxRefused(id: await firstJob(kit, host), kind: .write, reason: "Pull request is locked")
        await #expect(throws: PRWorkerError.refused("Pull request is locked")) { try await sent.value }
        #expect(kit.model.lateRefusal == nil)
        #expect(host.events == [.wrote(.comment, .failed(.refused))], "the screen shows it; the host hears how it went")
    }

    @Test func aLateRefusalOfAWriteQuotesItAsGitHubs() async throws {
        let (kit, host) = kit()
        let ref = ref
        _ = try await pastTheWait(kit) { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        let words = "GitHub refused your comment “Ship it.” on acme/api#7: Pull request is locked"
        #expect(kit.model.lateRefusal == words)
        #expect(host.events == [.wrote(.comment, .queued), .writeRefused(words)])
    }

    @Test func aLateRefusalOfAQuestionIsNeverGitHubs() async throws {
        let (kit, host) = kit()
        let question = PRAskQuestion(question: "Is it tested?", head: String(repeating: "a", count: 40), anchor: nil)
        let ref = ref
        #expect(try await pastTheWait(kit) { try await kit.model.ask(question, about: ref) } == .queued)
        #expect(kit.model.hasQueuedQuestion(about: ref))
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .question, reason: "Spending limit reached.")
        let words = "Your question “Is it tested?” to the AI on acme/api#7 couldn't be sent: Spending limit reached."
        #expect(kit.model.lateRefusal == words)
        #expect(!words.contains("GitHub"))
        #expect(host.events.last == .questionRefused(words))
    }

    @Test func aLateAnswerIsDroppedNotKeptForAScreenThatWentAway() async throws {
        let (kit, host) = kit()
        let ref = ref
        _ = try await pastTheWait(kit) { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "late")
        #expect(kit.model.lateRefusal == "GitHub refused a write: late", "the job's record went with its answer")
    }

    @Test func aViewedMarkSavedForLaterSaysNothing() async throws {
        let (kit, _) = kit()
        let ref = ref
        let outcome = try await pastTheWait(kit) {
            try await kit.model.write(.viewed(pullRequest: "p", path: "f", viewed: true), to: ref)
        }
        guard case .queued = outcome else {
            Issue.record("a Viewed mark is queued")
            return
        }
        #expect(!PRWrite.viewed(pullRequest: "p", path: "f", viewed: true).saysWhenQueued)
    }

    @Test func mergeGoesNowOrNotAtAll() async {
        let (kit, host) = kit()
        await #expect(throws: PRWorkerError.notPaired) {
            try await kit.model.write(.merge(method: "squash", commit: "c"), to: ref)
        }
        #expect(host.held.jobs.isEmpty)
    }

    @Test func cancellingAnOutboxWaitStopsWaitingAndKeepsTheQueuedJob() async throws {
        let (kit, host) = kit()
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        _ = try await firstJob(kit, host)
        sent.cancel()
        await #expect(throws: CancellationError.self) { try await sent.value }
        #expect(kit.model.waiting.isEmpty)
        #expect(kit.model.queued["job-1"]?.kind == .write, "cancelling a screen does not discard the host's job")
        #expect(host.events.isEmpty, "a cancelled wait reports no completed action")
    }

    @Test func anAnswerDeliveredBeforeCancellationStillCompletesTheWrite() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        let id = try await firstJob(kit, host)
        kit.outboxAnswered(id: id, data: Self.detail)
        sent.cancel()
        let outcome = try await sent.value
        #expect(outcome.posted?.mergeState == "CLEAN")
        #expect(kit.model.outcomes.isEmpty)
        #expect(kit.model.queued.isEmpty)
        #expect(kit.model.waiting.isEmpty)
        #expect(host.events == [.wrote(.comment, .done)])
    }

    private static func thread() throws -> PullRequestDetail.Thread {
        try JSONDecoder().decode(PullRequestDetail.Thread.self, from: Data("""
        {"id":"t","isResolved":false,"path":"f","line":1,"diffSide":"RIGHT","comments":{"nodes":[]}}
        """.utf8))
    }
}
