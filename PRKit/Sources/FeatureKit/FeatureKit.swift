import DurableNetworking
@_exported import FeedbackKit
import Foundation
import PRKitCore

// FeatureKit is FeedbackKit (jai/feedbackkit) over PRKit's Worker client: an app that already has a `PRViewerClient`
// sends its feedback through the same connection.

/// FeedbackKit's connection through a `PRViewerClient`: its bearer, its deadline, and refusals in the Worker's words.
/// With `kept`, each read's last good answer stays on the device and answers that read while there is no network: the
/// Feedback screen opens on its chats offline, under the host's offline banner. On the phone `kept` is a `ReadStore`; a
/// unit test passes one in memory.
struct PRViewerFeedbackConnection: FeedbackConnection {
    let viewer: PRViewerClient
    var kept: (any PRKeptStore)?

    func read<Answer: Decodable & Sendable>(_ path: String, as type: Answer.Type) async throws -> Answer {
        guard let kept else {
            return try await viewer.read(path, as: type)
        }
        let key = InboxKey("feedback-\(path)")
        do {
            let data = try await viewer.readData(path)
            let answer = try viewer.decode(type, from: data, path: path)
            try? kept.save(KeptAnswer(data: data, savedAt: .now), for: key)
            return answer
        } catch {
            guard ReadFailure.of(error) == .offline, let saved = kept.load(key),
                  let answer = try? JSONDecoder().decode(type, from: saved.data)
            else {
                throw error
            }
            return answer
        }
    }

    func send<Body: Encodable & Sendable, Answer: Decodable & Sendable>(
        _ path: String, _ body: Body, as type: Answer.Type
    ) async throws -> Answer {
        try await viewer.send(path, body, as: type)
    }
}

public extension FeatureClient {
    /// Over a client the host already has (PRKit's), sharing its connection. With `keptIn`, each read's last good
    /// answer is kept in that folder and shown while there is no network.
    init(viewer: PRViewerClient, samples: FeatureSamples? = nil, keptIn folder: URL? = nil) {
        let kept = folder.map { ReadStore(directory: $0) }
        self.init(connection: PRViewerFeedbackConnection(viewer: viewer, kept: kept), samples: samples)
    }

    /// Over the host's transport (DurableNetworking).
    init(access: PRViewerAccess, transport: any HTTPTransport, samples: FeatureSamples? = nil) {
        self.init(viewer: PRViewerClient(access: access, transport: transport), samples: samples)
    }
}
