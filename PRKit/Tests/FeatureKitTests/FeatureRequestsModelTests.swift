import Foundation
import PRKitCore
import Testing
@testable import FeatureKit

/// The feature-request routes as the Worker answers them, and a conversation going from new to a thread.
@MainActor
struct FeatureRequestsModelTests {
    /// A Worker that answers each route with a fixed body and keeps what it was asked.
    final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var requests: [String] { lock.withLock { seen } }

        func answer(_ request: URLRequest) -> (Data, URLResponse) {
            let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
            lock.withLock { seen.append(route) }
            let body = switch route {
            case "GET /feedback":
                #"{"threads": [{"id": "sesn_1", "title": "Bigger clock", "createdAt": "2026-11-05T09:00:00Z"}], "#
                    + #""builderOnline": true}"#
            default:
                #"{"id": "sesn_1", "isWorking": true, "builderOnline": true, "messages": ["#
                    + #"{"id": "e1", "role": "you", "text": "Bigger clock", "anchor": null}]}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func client(_ worker: Worker) -> FeatureClient {
        let access = PRViewerAccess(
            baseURL: { URL(string: "https://worker.example.com")! }, bearer: { "token" }, discard: {}
        )
        return FeatureClient(viewer: PRViewerClient(access: access, exchange: { worker.answer($0) }))
    }

    /// Each message's screenshot count; a Worker from before them sends none.
    @Test func aChatCountsScreenshots() throws {
        let json = #"{"id": "sesn_1", "isWorking": false, "builderOnline": true, "costCents": 3, "messages": ["#
            + #"{"id": "e1", "role": "you", "text": "", "anchor": null, "images": 2},"#
            + #"{"id": "e2", "role": "agent", "text": "Done", "anchor": null}]}"#
        let chat = try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))
        #expect(chat.screenshots == ["e1": 2] && chat.messages.count == 2)
    }

    @Test func aChatNamesTheAgentsCodingThread() throws {
        let json = #"{"id":"sesn_1","messages":[],"isWorking":true,"builderOnline":true,"thread": "#
            + #"{"host":"builder","id":"codex:session-1"}}"#
        let chat = try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))

        #expect(chat.thread == FeatureAgentThread(host: "builder", id: "codex:session-1"))
    }

    @Test func aChatWithoutAnAgentThreadKeepsTheFeedbackConversation() throws {
        for thread in ["", #", "thread": null"#] {
            let json = #"{"id":"sesn_1","messages":[],"isWorking":false,"builderOnline":true"# + thread + "}"
            let chat = try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))
            #expect(chat.thread == nil)
        }
    }

    @Test func aThreadMustNameBothItsHostAndSession() throws {
        let json = #"{"id":"sesn_1","messages":[],"isWorking":true,"builderOnline":true,"thread": "#
            + #"{"host":"builder"}}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))
        }
    }

    @Test func blankThreadMetadataKeepsTheFeedbackConversation() throws {
        for thread in [#"{"host":" ","id":"codex:session-1"}"#, #"{"host":"builder","id":""}"#] {
            let json = #"{"id":"sesn_1","messages":[],"isWorking":true,"builderOnline":true,"thread": "#
                + thread + "}"
            let chat = try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))
            #expect(chat.thread == nil)
        }
    }

    @Test func sampleChatsCanNameAnAgentThreadAndOlderInitializersStayEmpty() {
        var chat = FeatureChat(
            id: "sesn_1", messages: [], isWorking: false, activity: nil, problem: nil,
            costCents: nil, builderOnline: true
        )
        #expect(chat.thread == nil)
        let thread = FeatureAgentThread(host: "builder", id: "codex:session-1")
        chat.thread = thread
        #expect(chat.thread == thread)
    }

    @Test func aHostStartsTheAgentThroughFeedbackAndKeepsLaterDraftsForItsThread() async {
        let worker = Worker()
        let model = FeatureRequestsModel(client: client(worker))
        let route = model.compose(reusing: nil)
        model.drafts[route.box] = "Bigger clock"
        await model.sendFirstMessage(route)
        #expect(model.thread(for: route) == "sesn_1")
        #expect(worker.requests == ["POST /feedback", "GET /feedback"])

        model.drafts[route.box] = "Keep this for the thread"
        await model.sendFirstMessage(route)
        #expect(model.draft(for: route.box) == "Keep this for the thread")
        #expect(worker.requests == ["POST /feedback", "GET /feedback"])
    }

    /// The first message of a new conversation makes the thread; the conversation keeps its route and goes on there.
    @Test func theFirstMessageMakesTheThread() async {
        let worker = Worker()
        let model = FeatureRequestsModel(client: client(worker))
        let route = model.compose(reusing: nil)
        model.drafts[route.box] = "Bigger clock"
        await model.send(route)
        #expect(model.thread(for: route) == "sesn_1")
        #expect(model.title(for: route) == "Bigger clock")
        #expect(model.compose(reusing: route) != route, "New starts afresh once the old one is a thread")
        #expect(worker.requests == ["POST /feedback", "GET /feedback"])
        model.drafts[route.box] = "And the badge"
        await model.send(route)
        #expect(worker.requests.last == "POST /feedback/sesn_1")
    }

    /// Samples: nothing reaches a Worker, and the agent answers a moment after a send.
    @Test func samplesAnswerWithoutAWorker() async throws {
        let samples = FeatureSamples(
            list: FeatureList(threads: [], builderOnline: true),
            chat: { FeatureChat(
                id: $0, messages: [], isWorking: false, activity: nil, problem: nil, costCents: 0, builderOnline: true
            ) },
            answer: "Got it."
        )
        let model = FeatureRequestsModel(client: FeatureClient(viewer: client(Worker()).viewer, samples: samples))
        let route = model.compose(reusing: nil)
        model.drafts[route.box] = "Bigger clock"
        await model.send(route)
        let thread = try #require(model.thread(for: route))
        #expect(model.chats[thread]?.isWorking == true)
        try await Task.sleep(for: .seconds(3.5))
        #expect(model.chats[thread]?.messages.last?.text == "Got it.")
    }
}
