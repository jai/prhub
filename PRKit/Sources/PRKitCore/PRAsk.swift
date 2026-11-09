import Foundation

/// A question on its way to the PR's AI agent (`worker/src/ask.ts`).
public struct PRAskQuestion: Encodable, Equatable, Sendable {
    public struct Anchor: Encodable, Equatable, Sendable {
        public let path: String
        public let line: Int
        public let side: String
        public var code: String?

        public init(path: String, line: Int, side: String, code: String? = nil) {
            self.path = path
            self.line = line
            self.side = side
            self.code = code
        }
    }

    public let question: String
    public let head: String
    public let anchor: Anchor?

    public init(question: String, head: String, anchor: Anchor?) {
        self.question = question
        self.head = head
        self.anchor = anchor
    }
}

/// The conversation as the Worker reads it from the session, which holds it.
public struct PRAskChat: Decodable, Equatable, Sendable {
    public struct Message: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let role: String
        public let text: String
        public let anchor: String?

        public init(id: String, role: String, text: String, anchor: String?) {
            self.id = id
            self.role = role
            self.text = text
            self.anchor = anchor
        }

        public var isJai: Bool { role == "you" }
    }

    public var messages: [Message]
    public var isWorking: Bool
    public var activity: String?
    public var problem: String?
    public var costCents: Int?

    public init(messages: [Message], isWorking: Bool, activity: String?, problem: String?, costCents: Int?) {
        self.messages = messages
        self.isWorking = isWorking
        self.activity = activity
        self.problem = problem
        self.costCents = costCents
    }
}
