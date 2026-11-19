import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing

/// The outbox (`PRHubOutbox`) saved to its file, under the PR screens' model, over a Worker that goes down and comes
/// back: a review and a question wait on disk while it is down and land when it is back; a comment it refuses then is
/// said on the list.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PRHubOutboxScreensTests {
    private let resources = IntegrationResources()
    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)

    @Test func eachJobWaitsOnDiskWhileTheWorkerIsDownAndLandsOrIsRefusedWhenItIsBack() async throws {
        let directory = resources.directory()
        let staging = resources.directory("staging")
        _ = PRSampleSet.prHub.seed(in: staging, defaults: resources.defaults())
        let worker = OutboxWorker(reads: PRHubStubWorker.Transport(samples: .prHub, staging: staging, isOffline: false))
        let changes = AsyncStream<Void>.makeStream()
        let file = directory.appending(path: "outbox.json")
        let access = PRViewerAccess(baseURL: { OutboxWorker.url }, bearer: { "outbox" }, discard: {})
        var backoff = OutboxBackoff()
        backoff.random = { 1 }
        // The outbox's clock: its wait before trying again lasts until the Worker is up, then that wait has passed.
        let clock = Shared(Date(timeIntervalSince1970: 1000))
        let outbox = PRHubOutbox(
            client: PRViewerClient(access: access, transport: worker), file: file, send: worker, backoff: backoff,
            now: { clock.with { $0 } },
            sleep: { wait in
                await worker.whenUp()
                clock.with { $0 += TimeInterval(wait.components.seconds) + TimeInterval(wait.components.attoseconds) / 1e18 }
            },
            changed: { changes.continuation.yield(()) }
        )
        let defaults = resources.defaults()
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), access: access,
            worker: OutboxWorker.url, isSample: false,
            usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults), outbox: outbox, transport: worker,
            storage: .onDisk(directory: directory, defaults: defaults, sampleConfiguration: resources.defaults()),
            build: PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: true, samples: true),
            alertPermission: resources.alertPermission(defaults: defaults), network: PRNetwork(isOnline: true)
        )
        outbox.kit = environment.prs
        let model = environment.prs.model
        // The screen's wait ends at once: what a job does after it is the outbox's.
        model.sleep = { _ in }
        await outbox.start(watchingNetwork: false).value
        #expect(await model.refresh(.foreground) == .changed)
        let head = try #require(model.rows.first { $0.id == "acme/web#412" }?.head)

        await worker.setDown(true)
        let review = try await model.write(.review(.approve, body: "", commit: head, comments: []), to: Self.checkout)
        #expect(review.posted == nil, "the review waits, not refused")
        let question = PRAskQuestion(question: "Is it tested?", head: head, anchor: nil)
        let asked = try await model.ask(question, about: Self.checkout)
        guard case .queued = asked else {
            Issue.record("the question waits, not refused: \(asked)")
            return
        }
        #expect(try Self.saved(file).count == 2, "both wait in the outbox's file")

        await worker.setDown(false)
        try await until(changes.stream) { !outbox.isQueued(.write, about: Self.checkout) &&
            !outbox.isQueued(.question, about: Self.checkout)
        }
        #expect(await worker.received == ["write", "ask"], "in order, once each")
        #expect(try Self.saved(file).isEmpty)
        #expect(model.lateRefusal == nil)

        await worker.setDown(true)
        _ = try await model.write(.comment(body: "Please refuse this"), to: Self.checkout)
        await worker.setDown(false)
        try await until(changes.stream) { !outbox.isQueued(.write, about: Self.checkout) }
        let refusal = try #require(model.lateRefusal, "a refusal after the screen's wait is said on the list")
        #expect(refusal.hasPrefix("GitHub refused") && refusal.contains("Please refuse this"))
        #expect(try Self.saved(file).isEmpty, "a refusal is not tried again")
    }

    /// Waits on the outbox's changes until `done` holds.
    private func until(_ changes: AsyncStream<Void>, _ done: () -> Bool) async throws {
        for await _ in changes where done() {
            return
        }
        Issue.record("the outbox's changes ended first")
    }

    private static func saved(_ file: URL) throws -> [OutboxItem] {
        try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: file))
    }
}

/// A Worker that reads from the sample PRs, takes writes and questions, refuses a comment that asks to be, and goes
/// down on the test's word. Down, every request fails as with no network, and the outbox's wait lasts until it is up.
private actor OutboxWorker: HTTPTransport {
    static let url = URL(string: "https://outbox.invalid")!
    private let reads: PRHubStubWorker.Transport
    private var isDown = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var received: [String] = []

    init(reads: PRHubStubWorker.Transport) {
        self.reads = reads
    }

    func setDown(_ down: Bool) {
        isDown = down
        if !down {
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func whenUp() async {
        guard isDown else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !isDown else {
            throw URLError(.notConnectedToInternet)
        }
        guard request.httpMethod == "POST", let url = request.url, let route = url.pathComponents.last else {
            return try await reads.send(request)
        }
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if body.contains("Please refuse this") {
            return answer(#"{"error":"The stand-in Worker refused this comment."}"#, to: url, status: 422)
        }
        received.append(route)
        if route == "ask" {
            return answer(#"{"messages":[{"id":"a1","role":"agent","text":"Yes."}],"isWorking":false}"#, to: url)
        }
        let sample = try #require(PRSampleSet.prHub.samples.first { $0.row.number == 412 })
        return (Data(sample.detail.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func answer(_ json: String, to url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
