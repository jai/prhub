@_exported import FeedbackKit
import DurableNetworking
import PRKitCore

// FeatureKit is FeedbackKit (jai/feedbackkit) over PRKit's Worker client: an app that already has a `PRViewerClient`
// sends its feedback through the same connection.

/// FeedbackKit's connection through a `PRViewerClient`: its bearer, its deadline, and refusals in the Worker's words.
struct PRViewerFeedbackConnection: FeedbackConnection {
    let viewer: PRViewerClient

    func read<Answer: Decodable & Sendable>(_ path: String, as type: Answer.Type) async throws -> Answer {
        try await viewer.read(path, as: type)
    }

    func send<Body: Encodable & Sendable, Answer: Decodable & Sendable>(
        _ path: String, _ body: Body, as type: Answer.Type
    ) async throws -> Answer {
        try await viewer.send(path, body, as: type)
    }
}

extension FeatureClient {
    /// Over a client the host already has (PRKit's), sharing its connection.
    public init(viewer: PRViewerClient, samples: FeatureSamples? = nil) {
        self.init(connection: PRViewerFeedbackConnection(viewer: viewer), samples: samples)
    }

    /// Over the host's transport (DurableNetworking).
    public init(access: PRViewerAccess, transport: any HTTPTransport, samples: FeatureSamples? = nil) {
        self.init(viewer: PRViewerClient(access: access, transport: transport), samples: samples)
    }
}
