import DurableNetworking
@testable import FeatureKit
import Foundation
@testable import PRKitCore
import Testing

/// Feedback's reads keep their last good answer, which answers the same read while there is no network.
struct FeatureKitKeptTests {
    private struct Answer: Codable, Equatable, Sendable {
        let title: String
    }

    private let storage = TestStorage()
    private var kept: ReadStore {
        ReadStore(directory: storage.directory)
    }

    private func connection(status: Int = 200, _ answer: @escaping @Sendable () throws -> Data) -> PRViewerFeedbackConnection {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let viewer = PRViewerClient(access: access) { request in
            try (answer(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return PRViewerFeedbackConnection(viewer: viewer, kept: kept)
    }

    @Test func aReadOnlineAnswersTheSameReadOffline() async throws {
        let body = try JSONEncoder().encode(Answer(title: "Dark mode"))
        _ = try await connection { body }.read("feedback", as: Answer.self)
        let offline = connection { throw URLError(.notConnectedToInternet) }
        #expect(try await offline.read("feedback", as: Answer.self) == Answer(title: "Dark mode"))
    }

    @Test func offlineWithNothingKeptStillFails() async {
        let offline = connection { throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await offline.read("feedback/fb_1", as: Answer.self) }
    }

    @Test func aRefusalIsNotAnsweredFromTheKeptCopy() async throws {
        let body = try JSONEncoder().encode(Answer(title: "Dark mode"))
        _ = try await connection { body }.read("feedback", as: Answer.self)
        let refusing = connection(status: 403) { Data(#"{"error":"Feedback is disabled."}"#.utf8) }
        await #expect(throws: PRWorkerError.self) { try await refusing.read("feedback", as: Answer.self) }
    }
}
