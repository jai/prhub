import Foundation
@testable import PRKit
@testable import PRKitCore
import PRKitTestSupport
import Synchronization
import Testing

/// A chat whose agent is at work is followed on reads the Worker holds until it changes (`Ask-Version`); a Worker that
/// can't hold one is polled every 2 seconds, as before.
@MainActor
struct PRAskHeldTests {
    /// Answers each read with the next of its script, the last one for good, and keeps what each read asked for.
    private final class Worker: Sendable {
        struct Answer {
            var isWorking = true
            var activity = "Reading the repo"
            var version: String?
            var status = 200
        }

        private let script: Mutex<[Answer]>
        private let asked = Mutex<[[String: String]]>([])

        init(_ script: [Answer]) {
            self.script = Mutex(script)
        }

        var queries: [[String: String]] {
            asked.withLock { $0 }
        }

        func answer(_ request: URLRequest) -> (Data, URLResponse) {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            asked.withLock { $0.append(query) }
            let answer = script.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
            let chat = """
            {"messages":[{"id":"q1","role":"you","text":"Is it tested?","anchor":null}],
            "isWorking":\(answer.isWorking),"activity":\(answer.isWorking ? "\"\(answer.activity)\"" : "null")}
            """
            let headers = answer.version.map { ["Ask-Version": $0] }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: headers
            )!
            return (answer.status == 204 ? Data() : Data(chat.utf8), response)
        }
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private let clock = TestClock()

    private func model(_ worker: Worker) -> PRsModel {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { worker.answer($0) }
        let model = PRsModel(client: client, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let clock = clock
        model.sleep = { try await clock.sleep(for: $0) }
        return model
    }

    @Test func eachReadAfterTheFirstIsHeldFromTheVersionBeforeIt() async throws {
        let worker = Worker([
            .init(version: "v1"), .init(version: "v1", status: 204), .init(activity: "Reading retry.ts", version: "v2"),
            .init(isWorking: false, version: "v3"),
        ])
        let model = model(worker)
        model.followAskAway(ref)
        for _ in 0 ..< 3 {
            try await clock.advance(by: PRSession.askHeldPause, afterSleepers: 1)
        }
        try await settle("the answer is unread") { model.askActivities[ref]?.phase == .answered }
        let held = { (version: String) in ["version": version, "wait": "10"] }
        #expect(worker.queries == [[:], held("v1"), held("v1"), held("v2")])
    }

    @Test func whatTheAgentIsDoingShowsAsItChanges() async throws {
        let worker = Worker([.init(version: "v1"), .init(activity: "Reading retry.ts", version: "v2")])
        let model = model(worker)
        model.followAskAway(ref)
        try await clock.advance(by: PRSession.askHeldPause, afterSleepers: 1)
        try await settle("the new step") { model.askActivities[ref]?.words == "Reading retry.ts…" }
        model.askSheetOpened(ref)
    }

    @Test func aWorkerThatCantHoldIsPolled() async throws {
        let worker = Worker([.init(), .init(isWorking: false)])
        let model = model(worker)
        model.followAskAway(ref)
        try await clock.advance(by: PRSession.askPollInterval, afterSleepers: 1)
        try await settle("the answer is unread") { model.askActivities[ref]?.phase == .answered }
        #expect(worker.queries == [[:], [:]])
    }

    @Test func aFailedReadStartsAgainWithoutAVersionAndWaitsLonger() async throws {
        let worker = Worker([
            .init(version: "v1"), .init(status: 502), .init(isWorking: false),
        ])
        let model = model(worker)
        model.followAskAway(ref)
        try await clock.advance(by: PRSession.askHeldPause, afterSleepers: 1)
        try await clock.advance(by: PRSession.askPollWait(afterFailures: 1), afterSleepers: 1)
        try await settle("the answer is unread") { model.askActivities[ref]?.phase == .answered }
        #expect(worker.queries == [[:], ["version": "v1", "wait": "10"], [:]])
    }

    @Test func theNextWaitIsASecondWhenHeldAndThePollsOtherwise() {
        #expect(PRSession.askPollWait(afterFailures: 0, isHeld: true) == PRSession.askHeldPause)
        #expect(PRSession.askPollWait(afterFailures: 0) == PRSession.askPollInterval)
        #expect(PRSession.askPollWait(afterFailures: 2, isHeld: true) == .seconds(8))
    }
}
