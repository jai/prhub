import DurableNetworking
import Foundation
import PRKit
import Synchronization

/// FeedbackKit's direct path goes through this transport, so each send says how it went: `feedback_sent`, or
/// `feedback_send_failed` with why. The Feedback screen shows only "Could not send feedback. Try again." and the kit
/// keeps the reason, so without this a failed send leaves no trace. Reads that fail are `request_failed` (area
/// `feedback`), once a minute at most, as PRKit's are. Nothing of a message is recorded: its kind, how many screenshots,
/// its size and how long it took.
final class PRHubFeedbackTransport: HTTPTransport {
    typealias Record = @Sendable (AnalyticsEvent) -> Void

    static let readFailureWindow: Duration = .seconds(60)

    private let inner: any HTTPTransport
    private let record: Record
    private let lastReadFailure = Mutex<ContinuousClock.Instant?>(nil)

    init(inner: any HTTPTransport = URLSessionTransport(policy: .quick), record: @escaping Record) {
        self.inner = inner
        self.record = record
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let sending = FeedbackSend(request)
        let started = ContinuousClock.now
        func elapsed() -> Int {
            let time = ContinuousClock.now - started
            return Int(time.components.seconds * 1000 + time.components.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let (data, response) = try await inner.send(request)
            let isOK = (200 ..< 300).contains(response.statusCode)
            if let sending {
                if !isOK {
                    record(.feedbackSendFailed(sending.took(elapsed()), .status(response.statusCode)))
                } else if sending.kind != .live {
                    record(.feedbackSent(sending.took(elapsed())))
                }
            } else if !isOK {
                readFailed(.status(response.statusCode))
            }
            return (data, response)
        } catch {
            if let failure = PRRequestFailure(transport: error) {
                if let sending {
                    record(.feedbackSendFailed(sending.took(elapsed()), failure))
                } else {
                    readFailed(failure)
                }
            }
            throw error
        }
    }

    private func readFailed(_ failure: PRRequestFailure) {
        let now = ContinuousClock.now
        let isDue = lastReadFailure.withLock { last in
            guard last.map({ now - $0 >= Self.readFailureWindow }) ?? true else {
                return false
            }
            last = now
            return true
        }
        if isDue {
            record(.requestFailed(.feedback, failure))
        }
    }
}

/// What a Feedback send is: a new chat, a reply in one, or a live chat's message (ACP), with its screenshots' count
/// and its size. Nil for a request that sends nothing.
public struct FeedbackSend: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case new, reply, live
    }

    public let kind: Kind
    public let images: Int
    public let kilobytes: Int
    public let milliseconds: Int

    public init(kind: Kind, images: Int, kilobytes: Int, milliseconds: Int) {
        self.kind = kind
        self.images = images
        self.kilobytes = kilobytes
        self.milliseconds = milliseconds
    }

    /// FeedbackKit's `POST v2/feedback` (new), `POST v2/feedback/<chat>` (reply) and `POST v2/acp` (live).
    init?(_ request: URLRequest) {
        guard request.httpMethod?.uppercased() == "POST", let url = request.url else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let version = parts.lastIndex(of: "v2") else {
            return nil
        }
        let route = parts[(version + 1)...]
        switch (route.first, route.count) {
        case ("feedback", 1): kind = .new
        case ("feedback", 2): kind = .reply
        case ("acp", 1): kind = .live
        default: return nil
        }
        let body = request.httpBody ?? Data()
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        images = (json?["images"] as? [Any])?.count ?? 0
        kilobytes = (body.count + 1023) / 1024
        milliseconds = 0
    }

    func took(_ milliseconds: Int) -> FeedbackSend {
        FeedbackSend(kind: kind, images: images, kilobytes: kilobytes, milliseconds: milliseconds)
    }
}
