import Foundation
import PRKitCore

/// One feature request, as the Worker lists it (`worker/src/feedback.ts` in Agent Pager's pr-worker).
public struct FeatureThread: Decodable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: String

    public init(id: String, title: String, createdAt: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

/// The requests and whether the builder Mac is taking work.
public struct FeatureList: Decodable, Equatable, Sendable {
    public var threads: [FeatureThread]
    public var builderOnline: Bool

    public init(threads: [FeatureThread], builderOnline: Bool) {
        self.threads = threads
        self.builderOnline = builderOnline
    }
}

/// One request's conversation with the builder agent: the Ask chat's shape, and whether the builder Mac is taking work.
public struct FeatureChat: Decodable, Equatable, Sendable {
    public var id: String
    public var messages: [PRAskChat.Message]
    public var isWorking: Bool
    public var activity: String?
    public var problem: String?
    public var costCents: Int?
    public var builderOnline: Bool
    /// How many screenshots each message carried, by its id; none for a message without.
    public var screenshots: [String: Int]

    public init(
        id: String, messages: [PRAskChat.Message], isWorking: Bool, activity: String?, problem: String?,
        costCents: Int?, builderOnline: Bool, screenshots: [String: Int] = [:]
    ) {
        self.id = id
        self.messages = messages
        self.isWorking = isWorking
        self.activity = activity
        self.problem = problem
        self.costCents = costCents
        self.builderOnline = builderOnline
        self.screenshots = screenshots
    }

    private enum CodingKeys: String, CodingKey {
        case id, messages, isWorking, activity, problem, costCents, builderOnline
    }

    /// The count a message's `images` gives; a Worker from before them sends none.
    private struct Counted: Decodable {
        var id: String
        var images: Int?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        messages = try container.decode([PRAskChat.Message].self, forKey: .messages)
        isWorking = try container.decode(Bool.self, forKey: .isWorking)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        costCents = try container.decodeIfPresent(Int.self, forKey: .costCents)
        builderOnline = try container.decode(Bool.self, forKey: .builderOnline)
        let counted = try container.decode([Counted].self, forKey: .messages)
        screenshots = Dictionary(counted.compactMap { message in
            message.images.flatMap { $0 > 0 ? (message.id, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// What goes to the builder: the words, the screenshots and the build the sender is on. `client_ref` makes a retry send
/// it once.
struct FeatureMessage: Encodable, Sendable {
    let text: String
    let build: String?
    let images: [MessageImage]
    // swiftlint:disable:next identifier_name
    let client_ref: String
}

/// Made-up requests and no Worker, for UI tests and screenshots: a send is answered a moment later.
public struct FeatureSamples: Sendable {
    public var list: FeatureList
    /// A listed request's conversation.
    public var chat: @Sendable (String) -> FeatureChat
    /// The agent's answer to anything sent.
    public var answer: String
    /// A picture each composer starts with in its tray; nil starts them empty.
    public var screenshot: Data?

    public init(
        list: FeatureList, chat: @escaping @Sendable (String) -> FeatureChat, answer: String, screenshot: Data? = nil
    ) {
        self.list = list
        self.chat = chat
        self.answer = answer
        self.screenshot = screenshot
    }
}

/// The Worker's feature-request routes. The host gives where they are and the bearer, as `PRKitHost.access` does.
public struct FeatureClient: Sendable {
    /// The routes' root on the Worker: `GET/POST feedback` and `GET/POST feedback/<id>`.
    static let root = "feedback"

    let viewer: PRViewerClient
    /// Set: nothing leaves the device (`FeatureSamples`).
    public let samples: FeatureSamples?

    /// `isInForeground` decides whether a request waits for a network: in the app, while someone is looking at it.
    public init(
        access: PRViewerAccess, isInForeground: @escaping @Sendable () async -> Bool, samples: FeatureSamples? = nil
    ) {
        self.init(viewer: PRViewerClient(access: access, isInForeground: isInForeground), samples: samples)
    }

    /// Over a client the host already has (PRKit's), sharing its connection.
    public init(viewer: PRViewerClient, samples: FeatureSamples? = nil) {
        self.viewer = viewer
        self.samples = samples
    }

    func list() async throws -> FeatureList {
        try await viewer.read(Self.root, as: FeatureList.self)
    }

    func chat(_ thread: String) async throws -> FeatureChat {
        try await viewer.read("\(Self.root)/\(thread)", as: FeatureChat.self)
    }

    /// To the thread, or as a new request when there is none: that makes the thread.
    func send(_ message: FeatureMessage, to thread: String?) async throws -> FeatureChat {
        try await viewer.send(thread.map { "\(Self.root)/\($0)" } ?? Self.root, message, as: FeatureChat.self)
    }
}
