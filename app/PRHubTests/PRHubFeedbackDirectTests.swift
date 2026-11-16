import DurableNetworking
import Foundation
import Testing
@testable import PRHub

/// Feedback's direct path (issue #53): the config names FeedbackKit's root, and tokens come from the Worker.
struct PRHubFeedbackDirectTests {
    private func config(_ json: String) throws -> DeviceConfig {
        try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
    }

    private func answer(_ token: String, _ expiresAt: String) -> String {
        #"{"token":"\#(token)","expires_at":"\#(expiresAt)","url":"https://feedback.example.com"}"#
    }

    @Test func theConfigNamesAnHTTPSRootOnly() throws {
        let root = #"{"url":"https://feedback.example.com"}"#
        let direct = try config(#"{"features":{"feedback":true},"feedback_direct":\#(root)}"#)
        #expect(direct.feedbackDirect?.url == URL(string: "https://feedback.example.com"))
        let http = #"{"features":{},"feedback_direct":{"url":"http://feedback.example.com"}}"#
        #expect(try config(http).feedbackDirect == nil)
        #expect(try config(#"{"features":{},"feedback_direct":"nonsense"}"#).feedbackDirect == nil)
        #expect(try config(#"{"features":{}}"#).feedbackDirect == nil)
    }

    @Test func aKeptConfigKeepsItsRoot() throws {
        let direct = try config(#"{"features":{},"feedback_direct":{"url":"https://feedback.example.com"}}"#)
        let again = try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(direct))
        #expect(again.feedbackDirect == direct.feedbackDirect)
    }

    @Test func aTokenIsKeptUntilAMinuteBeforeItEndsAndRenewAsksAgain() async throws {
        let later = Date.now.addingTimeInterval(15 * 60)
            .ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let worker = StubWorker([
            .reply(status: 200, body: answer("one", later)), .reply(status: 200, body: answer("two", later)),
        ])
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let tokens = PRHubFeedbackTokens(client: PRViewerClient(access: access) { try await worker.exchange($0) })

        #expect(try await tokens.token(renew: false) == "one")
        #expect(try await tokens.token(renew: false) == "one", "kept, not asked again")
        #expect(try await tokens.token(renew: true) == "two", "FeedbackKit refused it: a new one")
        let sent = worker.requests.with { $0 }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.httpMethod == "POST" && $0.url?.path() == "/feedback/token" })
    }

    @Test func aTokenAboutToEndIsNotKept() async throws {
        let soon = Date.now.addingTimeInterval(30).ISO8601Format()
        let worker = StubWorker([
            .reply(status: 200, body: answer("one", soon)), .reply(status: 200, body: answer("two", soon)),
        ])
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let tokens = PRHubFeedbackTokens(client: PRViewerClient(access: access) { try await worker.exchange($0) })
        #expect(try await tokens.token(renew: false) == "one")
        #expect(try await tokens.token(renew: false) == "two")
    }
}
