import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

/// PR writes and questions saved on the device until the Worker has them (`PRHubOutbox`, issue #52).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PRHubOutboxTests {
    private let resources = IntegrationResources()
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

    private var file: URL {
        resources.directory("outbox.json")
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
            client: PRViewerClient(access: access, transport: StubTransport(worker: worker)), file: file,
            send: StubTransport(worker: worker), backoff: backoff, now: { clock.with { $0 } },
            sleep: { duration in
                try Task.checkCancellation()
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                clock.with { $0 += seconds }
            }, changed: { changes.yield(()) }
        )
    }

    private func waitUntilEmpty(_ outbox: PRHubOutbox, worker: StubWorker, attempts: Int) async throws {
        for await _ in changes.stream {
            let saved = try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: file))
            if saved.isEmpty, !outbox.isQueued(.write, about: ref), worker.requests.with(\.count) == attempts {
                return
            }
        }
        Issue.record("outbox changes ended before the saved queue drained")
    }

    @Test func aWriteSavedOfflineGoesAfterARelaunchCarryingItsIdAsClientRef() async throws {
        let offline = outbox(StubWorker([]))
        // Not started: as in a launch that ended before any network, nothing went out.
        let id = try await offline.enqueue(job)
        #expect(offline.isQueued(.write, about: ref))

        let worker = StubWorker([.reply(status: 200, body: "{}")])
        let relaunched = outbox(worker)
        await relaunched.start(watchingNetwork: false).value
        try await waitUntilEmpty(relaunched, worker: worker, attempts: 1)

        let sent = try #require(worker.requests.with { $0.first })
        #expect(sent.url?.path() == "/prs/acme/web/7/write")
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["client_ref"] as? String == id)
        #expect(!relaunched.isQueued(.write, about: ref))
    }

    @Test func aRefusalIsDroppedNotSentAgain() async throws {
        let worker = StubWorker([.reply(status: 422, body: #"{"error":"Pull request is closed"}"#)])
        let outbox = outbox(worker)
        _ = try await outbox.enqueue(job)
        await outbox.start(watchingNetwork: false).value
        try await waitUntilEmpty(outbox, worker: worker, attempts: 1)
        #expect(!outbox.isQueued(.write, about: ref))
        let relaunched = self.outbox(worker)
        await relaunched.start(watchingNetwork: false).value
        #expect(!relaunched.isQueued(.write, about: ref))
        #expect(worker.requests.with(\.count) == 1, "a refusal is not tried again")
    }

    @Test func aServerErrorIsTriedAgainUntilTheWorkerHasIt() async throws {
        let worker = StubWorker([.reply(status: 503, body: "{}"), .reply(status: 200, body: "{}")])
        let outbox = outbox(worker)
        _ = try await outbox.enqueue(job)
        await outbox.start(watchingNetwork: false).value
        try await waitUntilEmpty(outbox, worker: worker, attempts: 2)
        #expect(!outbox.isQueued(.write, about: ref))
        #expect(worker.requests.with(\.count) == 2)
    }

    @Test func forgetEmptiesItSoNothingGoesToTheNextWorker() async throws {
        let offline = outbox(StubWorker([]))
        _ = try await offline.enqueue(job)
        await offline.forget()
        #expect(!offline.isQueued(.write, about: ref))

        let worker = StubWorker([.reply(status: 200, body: "{}")])
        let relaunched = outbox(worker)
        await relaunched.start(watchingNetwork: false).value
        #expect(!relaunched.isQueued(.write, about: ref))
        #expect(try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: file)).isEmpty)
        #expect(worker.requests.with(\.count) == 0)
    }
}
