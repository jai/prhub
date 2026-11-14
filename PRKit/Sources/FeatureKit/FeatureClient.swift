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
    /// What sending does, when the Worker says (an issue Worker: a public GitHub issue); nil is the coding agent.
    public var notice: String?

    public init(threads: [FeatureThread], builderOnline: Bool, notice: String? = nil) {
        self.threads = threads
        self.builderOnline = builderOnline
        self.notice = notice
    }
}

/// The coding thread the feedback agent runs in, once the runner has started it.
public struct FeatureAgentThread: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let id: String

    public init(host: String, id: String) {
        self.host = host
        self.id = id
    }
}

/// What the feedback runner knows of a message. Missing or newer states stay unknown until it confirms delivery.
public enum FeatureMessageDelivery: Equatable, Sendable, Decodable {
    case pending
    case delivering
    case delivered
    case failed
    case unknown

    public init(from decoder: any Decoder) throws {
        self = switch try decoder.singleValueContainer().decode(String.self) {
        case "pending": .pending
        case "delivering": .delivering
        case "delivered": .delivered
        case "failed": .failed
        default: .unknown
        }
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
    /// The agent's coding thread. A host with its own thread conversation can use that same reply path here.
    public var thread: FeatureAgentThread?
    /// How many screenshots each message carried, by its id; none for a message without.
    public var screenshots: [String: Int]
    /// Only the sender's messages have delivery states; agent messages do not travel through the runner's queue.
    public var delivery: [String: FeatureMessageDelivery]

    public var hasUndeliveredMessages: Bool { delivery.values.contains { $0 != .delivered } }

    public init(
        id: String, messages: [PRAskChat.Message], isWorking: Bool, activity: String?, problem: String?,
        costCents: Int?, builderOnline: Bool, screenshots: [String: Int] = [:], thread: FeatureAgentThread? = nil,
        delivery: [String: FeatureMessageDelivery] = [:]
    ) {
        self.id = id
        self.messages = messages
        self.isWorking = isWorking
        self.activity = activity
        self.problem = problem
        self.costCents = costCents
        self.builderOnline = builderOnline
        self.thread = thread
        self.screenshots = screenshots
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey {
        case id, messages, isWorking, activity, problem, costCents, builderOnline, thread
    }

    /// The screenshot count and persisted delivery state; a Worker from before either field sends none.
    private struct MessageMetadata: Decodable {
        var id: String
        var images: Int?
        var status: FeatureMessageDelivery?
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
        if let agentThread = try container.decodeIfPresent(FeatureAgentThread.self, forKey: .thread),
           !agentThread.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !agentThread.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread = agentThread
        } else {
            thread = nil
        }
        let metadata = try container.decode([MessageMetadata].self, forKey: .messages)
        screenshots = Dictionary(metadata.compactMap { message in
            message.images.flatMap { $0 > 0 ? (message.id, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
        let sent = Set(messages.filter(\.isJai).map(\.id))
        delivery = Dictionary(metadata.filter { sent.contains($0.id) }.map { message in
            (message.id, message.status ?? .unknown)
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
