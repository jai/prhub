import Foundation
@testable import PRKit
@testable import PRKitCore
import PRKitTestSupport
import Testing

/// A PR's Ask chat keeps its last good answer: the sheet opens on it, offline too, after a relaunch. A relaunch is a
/// second model over the first one's storage.
@MainActor
struct PRAskKeptTests {
    private let storage = PRKitStorage.inMemory()

    private let ref = PullRequestRef(repo: "acme/web", number: 7)
    private nonisolated static let chat = Data("""
    {"messages":[{"id":"q1","role":"you","text":"Is this tested?","anchor":null},
    {"id":"a1","role":"agent","text":"Yes, in CheckoutTests.","anchor":null}],"isWorking":false}
    """.utf8)

    private func client(offline: Bool) -> PRViewerClient {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        return PRViewerClient(access: access) { request in
            if offline {
                throw URLError(.notConnectedToInternet)
            }
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.chat, ok)
        }
    }

    @Test func aChatReadOnlineIsThereOfflineAfterARelaunch() async throws {
        let online = PRsModel(client: client(offline: false), storage: storage, network: PRNetwork(isOnline: true))
        _ = try await online.askChat(ref)

        let relaunched = PRsModel(client: client(offline: true), storage: storage, network: PRNetwork(isOnline: true))
        #expect(relaunched.keptAskChat(ref)?.messages.map(\.id) == ["q1", "a1"])
        await #expect(throws: URLError.self) { try await relaunched.askChat(ref) }
        #expect(relaunched.keptAskChat(ref)?.messages.count == 2, "a failed read leaves the kept chat")
    }

    @Test func anotherPRHasNoKeptChat() async throws {
        let model = PRsModel(client: client(offline: false), storage: storage, network: PRNetwork(isOnline: true))
        _ = try await model.askChat(ref)
        #expect(model.keptAskChat(PullRequestRef(repo: "acme/web", number: 8)) == nil)
    }
}
