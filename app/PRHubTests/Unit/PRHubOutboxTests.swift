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
