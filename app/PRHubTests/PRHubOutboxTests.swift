import DurableNetworking
import Foundation
@testable import PRHubCore
import Testing

/// PR writes and questions saved on the device until the Worker has them (`PRHubOutbox`, issue #52).
@MainActor
struct PRHubOutboxTests {
    private struct StubTransport: HTTPTransport {
        let worker: StubWorker

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await worker.exchange(request)
            // swiftlint:disable:next force_cast
            return (data, response as! HTTPURLResponse)
        }
    }

    private let file = URL.temporaryDirectory.appending(path: "pr-outbox-\(UUID().uuidString).json")
    private let ref = PullRequestRef(repo: "acme/web", number: 7)
    private let job = PROutboxJob.write(.comment(body: "Looks good"), ref: PullRequestRef(repo: "acme/web", number: 7))

    private func outbox(_ worker: StubWorker) -> PRHubOutbox {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        return PRHubOutbox(
            client: PRViewerClient(access: access, transport: StubTransport(worker: worker)), file: file,
            send: StubTransport(worker: worker)
        )
    }

    /// Waits up to 15 s (the outbox's backoff tops out at 10 s) for `done`.
    private func eventually(_ done: () -> Bool) async throws {
        for _ in 0 ..< 150 where !done() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aWriteSavedOfflineGoesAfterARelaunchCarryingItsIdAsClientRef() async throws {
        let offline = outbox(StubWorker([]))
        // Not started: as in a launch that ended before any network, nothing went out.
        let id = try await offline.enqueue(job)
        #expect(offline.isQueued(.write, about: ref))

        let worker = StubWorker([.reply(status: 200, body: "{}")])
        let relaunched = outbox(worker)
        relaunched.start()
        try await eventually { !relaunched.isQueued(.write, about: ref) && worker.requests.with(\.count) == 1 }

        let sent = try #require(worker.requests.with { $0.first })
        #expect(sent.url?.path() == "/prs/acme/web/7/write")
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["client_ref"] as? String == id)
        #expect(!relaunched.isQueued(.write, about: ref))
    }

    @Test func aRefusalIsDroppedNotSentAgain() async throws {
        let worker = StubWorker([.reply(status: 422, body: #"{"error":"Pull request is closed"}"#)])
        let outbox = outbox(worker)
        outbox.start()
        _ = try await outbox.enqueue(job)
        try await eventually { !outbox.isQueued(.write, about: ref) }
        #expect(!outbox.isQueued(.write, about: ref))
        try await Task.sleep(for: .seconds(2))
        #expect(worker.requests.with(\.count) == 1, "a refusal is not tried again")
    }

    @Test func aServerErrorIsTriedAgainUntilTheWorkerHasIt() async throws {
        let worker = StubWorker([.reply(status: 503, body: "{}"), .reply(status: 200, body: "{}")])
        let outbox = outbox(worker)
        outbox.start()
        _ = try await outbox.enqueue(job)
        try await eventually { !outbox.isQueued(.write, about: ref) }
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
        relaunched.start()
        try await Task.sleep(for: .seconds(1))
        #expect(worker.requests.with(\.count) == 0)
    }
}
