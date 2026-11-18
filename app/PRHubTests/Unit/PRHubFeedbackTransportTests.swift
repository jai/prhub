import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

/// Each Feedback send on the direct path says how it went, since the screen says only "Could not send feedback".
struct PRHubFeedbackTransportTests {
    private struct Stub: HTTPTransport {
        let worker: StubWorker

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await worker.exchange(request)
            return (data, response as! HTTPURLResponse) // swiftlint:disable:this force_cast
        }
    }

    private final class Recorded: Sendable {
        let events = Shared<[AnalyticsEvent]>([])
        var all: [AnalyticsEvent] {
            events.with { $0 }
        }
    }

    private func transport(_ answers: [StubWorker.Answer]) -> (PRHubFeedbackTransport, Recorded) {
        let recorded = Recorded()
        let transport = PRHubFeedbackTransport(inner: Stub(worker: StubWorker(answers))) { event in
            recorded.events.with { $0.append(event) }
        }
        return (transport, recorded)
    }

    private func post(_ path: String, _ body: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://feedback.example.com/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return request
    }

    /// The event without its time, which a test cannot fix.
    private func untimed(_ event: AnalyticsEvent) -> AnalyticsEvent {
        switch event {
        case let .feedbackSent(send):
            .feedbackSent(send.took(0))
        case let .feedbackSendFailed(send, failure):
            .feedbackSendFailed(send.took(0), failure)
        default:
            event
        }
    }

    @Test func aNewChatThatIsTakenIsSentWithItsScreenshotsAndSize() async throws {
        let (transport, recorded) = transport([.reply(status: 200, body: "{}")])
        let body = #"{"text":"secret words","images":[{"jpeg":"AAAA"},{"jpeg":"BBBB"}]}"#
        _ = try await transport.send(post("v2/feedback", body))
        #expect(recorded.all.map(untimed) == [
            .feedbackSent(FeedbackSend(kind: .new, images: 2, kilobytes: 1, milliseconds: 0)),
        ])
    }

    @Test func aReplyThatTimesOutSaysSoAndStillFails() async {
        let (transport, recorded) = transport([.fail(.timedOut)])
        await #expect(throws: URLError.self) {
            try await transport.send(post("v2/feedback/fb_1", #"{"text":"hi","images":[]}"#))
        }
        #expect(recorded.all.map(untimed) == [
            .feedbackSendFailed(FeedbackSend(kind: .reply, images: 0, kilobytes: 1, milliseconds: 0), .timeout),
        ])
    }

    @Test func aRefusedSendSaysItsStatus() async throws {
        let (transport, recorded) = transport([.reply(status: 413, body: "")])
        _ = try await transport.send(post("v2/feedback", "{}"))
        #expect(recorded.all.map(untimed) == [
            .feedbackSendFailed(FeedbackSend(kind: .new, images: 0, kilobytes: 1, milliseconds: 0), .status(413)),
        ])
    }

    @Test func aLiveChatsMessageIsRecordedOnlyWhenItFails() async throws {
        let (transport, recorded) = transport([.reply(status: 202, body: ""), .fail(.notConnectedToInternet)])
        _ = try await transport.send(post("v2/acp", "{}"))
        _ = try? await transport.send(post("v2/acp", "{}"))
        #expect(recorded.all.map(untimed) == [
            .feedbackSendFailed(FeedbackSend(kind: .live, images: 0, kilobytes: 1, milliseconds: 0), .offline),
        ])
    }

    @Test func failedReadsAreOneRequestFailedAMinute() async throws {
        let (transport, recorded) = transport([.reply(status: 500, body: ""), .fail(.timedOut)])
        let read = try URLRequest(url: #require(URL(string: "https://feedback.example.com/v2/feedback")))
        _ = try? await transport.send(read)
        _ = try? await transport.send(read)
        #expect(recorded.all == [.requestFailed(.feedback, .status(500))])
    }

    @Test func aCancelledSendIsNoFailure() async {
        let (transport, recorded) = transport([.fail(.cancelled)])
        _ = try? await transport.send(post("v2/feedback", "{}"))
        #expect(recorded.all.isEmpty)
    }

    @Test func theEventsCarryNoWordsOfTheMessage() {
        let event = AnalyticsEvent.feedbackSendFailed(
            FeedbackSend(kind: .new, images: 1, kilobytes: 900, milliseconds: 15000), .timeout
        )
        #expect(event.name == "feedback_send_failed")
        #expect(event.properties == [
            "kind": .word("new"), "images": .number(1), "kb": .number(900), "ms": .number(15000),
            "failure": .word("timeout"),
        ])
    }
}
