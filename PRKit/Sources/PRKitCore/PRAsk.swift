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

/// A review the agent drafted when asked (`draft_review`, docs/api.md "Drafted reviews"). Nothing posts it but Jai:
/// he adds it to his drafts or posts it, as himself.
public struct PRAskDraft: Decodable, Equatable, Sendable {
    public struct Comment: Decodable, Equatable, Sendable {
        public let path: String
        public let line: Int
        public let side: PRDiffSide
        public let body: String

        public init(path: String, line: Int, side: PRDiffSide, body: String) {
            self.path = path
            self.line = line
            self.side = side
            self.body = body
        }
    }

    /// GitHub's review event, `APPROVE`, `REQUEST_CHANGES` or `COMMENT`.
    public let event: String
    public let body: String
    public let comments: [Comment]

    public init(event: PRReviewEvent, body: String, comments: [Comment]) {
        self.event = event.rawValue
        self.body = body
        self.comments = comments
    }

    /// Nil for an event this app sends no review for.
    public var reviewEvent: PRReviewEvent? { PRReviewEvent(rawValue: event) }

    /// The line comments as Jai's own drafts, each new.
    public var draftComments: [PRDraftComment] {
        comments.map { PRDraftComment(id: UUID(), path: $0.path, line: $0.line, side: $0.side, body: $0.body) }
    }
}

/// A comment Ask AI proposed on one of the PR's Linear tickets (`linear_act`, docs/api.md "Commenting on Linear").
/// Nothing posts it but Jai's yes: the Worker then posts it with his own Linear key, as him.
public struct PRAskLinearCard: Decodable, Equatable, Sendable {
    public struct Mention: Decodable, Equatable, Sendable {
        public struct User: Decodable, Equatable, Sendable {
            public let name: String
            /// An app user, such as Octobot: Linear starts an agent session for it.
            public let agent: Bool

            public init(name: String, agent: Bool) {
                self.name = name
                self.agent = agent
            }

            private enum CodingKeys: String, CodingKey { case name, agent }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                agent = try container.decodeIfPresent(Bool.self, forKey: .agent) ?? false
            }
        }

        /// As the agent wrote it, without the @.
        public let written: String
        /// Who Linear notifies; nil when nobody, or more than one person, matches.
        public let user: User?

        public init(written: String, user: User?) {
            self.written = written
            self.user = user
        }
    }

    /// The agent session the comment's mention started.
    public struct Session: Decodable, Equatable, Sendable {
        public let agent: String?
        /// Linear's: `pending`, `active`, `awaitingInput`, `complete`, `error`, `stale`, …
        public let status: String
        public let url: URL?

        public init(agent: String?, status: String, url: URL?) {
            self.agent = agent
            self.status = status
            self.url = url
        }
    }

    public enum State: String, Decodable, Sendable {
        case proposed, posted, failed
    }

    /// The ticket's key, `ENG-12`.
    public let issue: String
    /// The words exactly as they post, each mention as the name of the user it reaches.
    public let text: String
    public let mentions: [Mention]
    /// Why it can't post; nil when it can.
    public let problem: String?
    public let state: State
    /// The posted comment.
    public let url: URL?
    /// Linear's reason the last post failed.
    public let failure: String?
    public let session: Session?

    public init(
        issue: String, text: String, mentions: [Mention], problem: String?, state: State, url: URL? = nil,
        failure: String? = nil, session: Session? = nil
    ) {
        self.issue = issue
        self.text = text
        self.mentions = mentions
        self.problem = problem
        self.state = state
        self.url = url
        self.failure = failure
        self.session = session
    }

    /// Whether Jai's yes would post it now.
    public var canPost: Bool { problem == nil && state != .posted }
}

/// The conversation as the Worker reads it from the session, which holds it.
public struct PRAskChat: Decodable, Equatable, Sendable {
    public struct Message: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let role: String
        public let text: String
        public let anchor: String?
        /// The anchored line's side, `LEFT` (old) or `RIGHT` (new); absent on older Workers and on whole-PR questions.
        public let side: String?
        /// On an answer: the review it drafted.
        public let draft: PRAskDraft?
        /// On an answer: the comments it proposed on the PR's Linear tickets.
        public let linear: [PRAskLinearCard]?

        public init(
            id: String, role: String, text: String, anchor: String?, side: String? = nil, draft: PRAskDraft? = nil,
            linear: [PRAskLinearCard]? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.anchor = anchor
            self.side = side
            self.draft = draft
            self.linear = linear
        }

        public var isJai: Bool { role == "you" }
    }

    public var messages: [Message]
    public var isWorking: Bool
    public var activity: String?
    public var problem: String?
    public var costCents: Int?

    private enum CodingKeys: String, CodingKey {
        case messages, isWorking, activity, problem, costCents
    }

    /// `costCents` is read as a number and rounded: a Worker that sends hundredths of a cent must not make the whole
    /// chat unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decode([Message].self, forKey: .messages)
        isWorking = try container.decode(Bool.self, forKey: .isWorking)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        costCents = try container.decodeIfPresent(Double.self, forKey: .costCents).map { Int($0.rounded()) }
    }

    public init(messages: [Message], isWorking: Bool, activity: String?, problem: String?, costCents: Int?) {
        self.messages = messages
        self.isWorking = isWorking
        self.activity = activity
        self.problem = problem
        self.costCents = costCents
    }
}
