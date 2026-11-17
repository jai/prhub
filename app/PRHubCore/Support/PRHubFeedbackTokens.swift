import Foundation
import PRKit

/// Tokens for FeedbackKit's direct path, from the Worker's `POST /feedback/token` (docs/api.md, "Feedback"): one is
/// kept until a minute before it ends, and a new one is asked for when FeedbackKit refused the last (`renew`).
actor PRHubFeedbackTokens {
    private struct Answer: Decodable, Sendable {
        let token: String
        // swiftlint:disable:next identifier_name
        let expires_at: String
    }

    private struct NoBody: Encodable, Sendable {}

    private let client: PRViewerClient
    private var kept: (token: String, until: Date)?

    init(client: PRViewerClient) {
        self.client = client
    }

    func token(renew: Bool) async throws -> String {
        if !renew, let kept, kept.until.timeIntervalSinceNow > 60 {
            return kept.token
        }
        let answer = try await client.send("feedback/token", NoBody(), as: Answer.self)
        // The Worker's `toISOString()` has milliseconds; an end it can't read is asked again next time.
        let until = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(answer.expires_at))
            ?? (try? Date.ISO8601FormatStyle().parse(answer.expires_at))
            ?? .now
        kept = (answer.token, until)
        return answer.token
    }
}
