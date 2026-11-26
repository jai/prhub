import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

/// PR writes and questions in a queue kept in memory until the Worker has them (`PRHubOutbox`, issue #52): a refusal is
/// dropped, a server error is tried again.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PRHubOutboxTests {
    private let changes = AsyncStream<Void>.makeStream()
    private let clock = Shared(Date(timeIntervalSince1970: 1000))
    private struct StubTransport: HTTPTransport {
        let worker: StubWorker

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await worker.exchange(request)
            // swiftlint:disable:next force_cast
            return (data, response as! HTTPURLResponse)
        }
    }

    private let ref = PullRequestRef(repo: "acme/web", number: 7)
    private let job = PROutboxJob.write(.comment(body: "Looks good"), ref: PullRequestRef(repo: "acme/web", number: 7))

    private func outbox(_ worker: StubWorker) -> PRHubOutbox {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let clock = clock
        let changes = changes.continuation
        var backoff = OutboxBackoff()
        backoff.random = { 1 }
        return PRHubOutbox(
            client: PRViewerClient(access: access, transport: StubTransport(worker: worker)), file: nil,
            send: StubTransport(worker: worker), backoff: backoff, now: { clock.with { $0 } },
            sleep: { duration in
                try Task.checkCancellation()
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                clock.with { $0 += seconds }
            }, changed: { changes.yield(()) }
        )
    }

    private func waitUntilEmpty(_ outbox: PRHubOutbox, worker: StubWorker, attempts: Int) async {
        for await _ in changes.stream {
            if !outbox.isQueued(.write, about: ref), worker.requests.with(\.count) == attempts {
                return
            }
        }
        Issue.record("outbox changes ended before the queue drained")
    }

    @Test func aRefusalIsDroppedNotSentAgain() async throws {
        let worker = StubWorker([.reply(status: 422, body: #"{"error":"Pull request is closed"}"#)])
        let outbox = outbox(worker)
        _ = try await outbox.enqueue(job)
        await outbox.start(watchingNetwork: false).value
        await waitUntilEmpty(outbox, worker: worker, attempts: 1)
        #expect(!outbox.isQueued(.write, about: ref))
        #expect(worker.requests.with(\.count) == 1, "a refusal is not tried again")
    }

    /// A pending comment changed before its add went: PRKit stops the job and sends the comment as it now reads.
    @Test func aJobNotTriedYetIsStoppedAndNeverSent() async throws {
        let worker = StubWorker([.reply(status: 200, body: "{}")])
        let outbox = outbox(worker)
        let id = try await outbox.enqueue(job)
        #expect(outbox.holds(job: id, about: ref))
        #expect(await outbox.cancel(id))
        #expect(!outbox.holds(job: id, about: ref) && !outbox.isQueued(.write, about: ref))
        #expect(await outbox.cancel(id) == false, "nothing is left to stop")
        let kept = try await outbox.enqueue(job)
        await outbox.start(watchingNetwork: false).value
        await waitUntilEmpty(outbox, worker: worker, attempts: 1)
        #expect(worker.requests.with(\.count) == 1, "only the job that was kept went")
        #expect(await outbox.cancel(kept) == false, "one the Worker has is not stopped")
    }

    /// Until the saved jobs are read, no job is known to be gone: PRKit sends a pending comment again only when it is.
    @Test func beforeTheSavedJobsAreReadEveryJobCountsAsHeld() async {
        let outbox = outbox(StubWorker([]))
        #expect(outbox.holds(job: "a-job-from-the-last-launch", about: ref))
        await outbox.start(watchingNetwork: false).value
        #expect(!outbox.holds(job: "a-job-from-the-last-launch", about: ref))
    }

    @Test func aServerErrorIsTriedAgainUntilTheWorkerHasIt() async throws {
        let worker = StubWorker([.reply(status: 503, body: "{}"), .reply(status: 200, body: "{}")])
        let outbox = outbox(worker)
        _ = try await outbox.enqueue(job)
        await outbox.start(watchingNetwork: false).value
        await waitUntilEmpty(outbox, worker: worker, attempts: 2)
        #expect(!outbox.isQueued(.write, about: ref))
        #expect(worker.requests.with(\.count) == 2)
    }
}
