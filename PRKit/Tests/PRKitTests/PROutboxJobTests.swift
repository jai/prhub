import Foundation
import Testing
@testable import PRKit

/// Each kind of outbox job in its own states and words: one delivery, never one meaning.
@MainActor
struct PROutboxJobTests {
    /// An outbox that keeps every job until the test answers or refuses it.
    @MainActor
    final class Outbox: PRKitOutbox {
        private(set) var jobs: [(id: String, job: PROutboxJob)] = []

        func enqueue(_ job: PROutboxJob) async throws -> String {
            let id = "job-\(jobs.count + 1)"
            jobs.append((id, job))
            return id
        }

        func isQueued(_ kind: PROutboxJob.Kind, about ref: PullRequestRef) -> Bool {
            jobs.contains { $0.job.kind == kind && $0.job.ref == ref }
        }
    }

    @MainActor
    final class Host: PRKitHost {
        let access = PRViewerAccess.offline
        let configuration = PRKitConfiguration.everything
        let held = Outbox()
        var outbox: (any PRKitOutbox)? { held }
        let apnsEnvironment = "sandbox"
        let samples: PRSampleSet? = nil
        let launchOptions = PRKitLaunchOptions.none
        private(set) var events: [PRKitEvent] = []

        func isInForeground() async -> Bool { false }
        func log(_ line: String) {}
        func receive(_ event: PRKitEvent) { events.append(event) }
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private static let detail = Data("""
    {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
    "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
    "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
    """.utf8)

    private func kit(wait: Duration = .milliseconds(50), isOnline: Bool = true) -> (PRKitController, Host) {
        let host = Host()
        let kit = PRKitController(host: host)
        kit.model.answerWait = wait
        kit.model.isOnline = { isOnline }
        return (kit, host)
    }

    private func firstJob(_ host: Host) async -> String {
        while host.held.jobs.isEmpty {
            await Task.yield()
        }
        return host.held.jobs[0].id
    }

    @Test func aWriteAnsweredInTimeIsPosted() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        kit.outboxAnswered(id: await firstJob(host), data: Self.detail)
        let outcome = try await sent.value
        #expect(outcome.posted?.mergeState == "CLEAN")
        guard case .write(.comment("Ship it."), ref) = host.held.jobs[0].job else {
            Issue.record("a comment goes as a write job")
            return
        }
    }

    @Test func aSlowWriteOnlineIsSendingAndSaysSoInTheWaitingTone() async throws {
        let (kit, _) = kit()
        let outcome = try await kit.model.write(.comment(body: "Ship it."), to: ref)
        guard case .queued(.sending) = outcome else {
            Issue.record("expected sending, got \(outcome)")
            return
        }
        let session = kit.model.session(for: ref)
        try await session.setResolved(true, thread: try Self.thread())
        #expect(session.notice == .queued(noun: "Resolving the thread", .sending))
        #expect(session.notice?.tone == .toneWaiting)
    }

    @Test func aWriteOfflineWaitsForTheNetwork() async throws {
        let (kit, _) = kit(isOnline: false)
        let outcome = try await kit.model.write(.review(.approve, body: "", commit: "c", comments: []), to: ref)
        guard case .queued(.waitingForNetwork) = outcome else {
            Issue.record("expected waiting for the network, got \(outcome)")
            return
        }
        #expect(PRNotice.queued(noun: "Your review", .waitingForNetwork).words.contains("back online"))
    }

    @Test func aRefusalInTimeIsThrownInGitHubsWords() async {
        let (kit, host) = kit(wait: .seconds(5))
        let sent = Task { try await kit.model.write(.comment(body: "Ship it."), to: ref) }
        kit.outboxRefused(id: await firstJob(host), kind: .write, reason: "Pull request is locked")
        await #expect(throws: PRWorkerError.refused("Pull request is locked")) { try await sent.value }
        #expect(kit.model.lateRefusal == nil && host.events.isEmpty)
    }

    @Test func aLateRefusalOfAWriteQuotesItAsGitHubs() async throws {
        let (kit, host) = kit()
        _ = try await kit.model.write(.comment(body: "Ship it."), to: ref)
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "Pull request is locked")
        let words = "GitHub refused your comment “Ship it.” on acme/api#7: Pull request is locked"
        #expect(kit.model.lateRefusal == words)
        #expect(host.events == [.writeRefused(words)])
    }

    @Test func aLateRefusalOfAQuestionIsNeverGitHubs() async throws {
        let (kit, host) = kit()
        let question = PRAskQuestion(question: "Is it tested?", head: String(repeating: "a", count: 40), anchor: nil)
        #expect(try await kit.model.ask(question, about: ref) == .queued)
        #expect(kit.model.hasQueuedQuestion(about: ref))
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .question, reason: "Spending limit reached.")
        let words = "Your question “Is it tested?” to the AI on acme/api#7 couldn't be sent: Spending limit reached."
        #expect(kit.model.lateRefusal == words)
        #expect(!words.contains("GitHub"))
        #expect(host.events == [.questionRefused(words)])
    }

    @Test func aLateAnswerIsDroppedNotKeptForAScreenThatWentAway() async throws {
        let (kit, host) = kit()
        _ = try await kit.model.write(.comment(body: "Ship it."), to: ref)
        kit.outboxAnswered(id: host.held.jobs[0].id, data: Self.detail)
        kit.outboxRefused(id: host.held.jobs[0].id, kind: .write, reason: "late")
        #expect(kit.model.lateRefusal == "GitHub refused a write: late", "the job's record went with its answer")
    }

    @Test func aViewedMarkSavedForLaterSaysNothing() async throws {
        let (kit, _) = kit()
        let outcome = try await kit.model.write(.viewed(pullRequest: "p", path: "f", viewed: true), to: ref)
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

    private static func thread() throws -> PullRequestDetail.Thread {
        try JSONDecoder().decode(PullRequestDetail.Thread.self, from: Data("""
        {"id":"t","isResolved":false,"path":"f","line":1,"diffSide":"RIGHT","comments":{"nodes":[]}}
        """.utf8))
    }
}
