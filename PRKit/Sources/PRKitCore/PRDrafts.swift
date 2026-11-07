import Foundation

/// A line comment waiting to go with a review. Kept on the phone until then, so it survives the app closing.
public struct PRDraftComment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let line: Int
    public let side: PRDiffSide
    public let body: String

    public init(id: UUID, path: String, line: Int, side: PRDiffSide, body: String) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.body = body
    }
}

/// One file per PR, in Application Support: a draft is Jai's words, so iOS clearing a cache must not take it.
public struct PRDraftStore: Sendable {
    public let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "pr-drafts", directoryHint: .isDirectory)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ ref: PullRequestRef) -> URL {
        directory.appending(path: "\(ref.repo.replacing("/", with: "__"))__\(ref.number).json")
    }

    public func load(_ ref: PullRequestRef) -> [PRDraftComment] {
        (try? Data(contentsOf: file(ref))).flatMap { try? JSONDecoder().decode([PRDraftComment].self, from: $0) } ?? []
    }

    public func save(_ drafts: [PRDraftComment], for ref: PullRequestRef) {
        if drafts.isEmpty {
            try? FileManager.default.removeItem(at: file(ref))
        } else if let data = try? JSONEncoder().encode(drafts) {
            try? data.write(to: file(ref), options: .atomic)
        }
    }
}

/// Jai's answer to a PR, on the phone from the moment GitHub takes it: the Worker's list only says so a sync later, and
/// a plain comment never changes it at all.
public struct PRLocalAnswer: Codable, Hashable, Sendable {
    public let review: String
    public let sentAt: String
    public let head: String

    public init(review: String, sentAt: String, head: String) {
        self.review = review
        self.sentAt = sentAt
        self.head = head
    }

    /// Done with once the Worker's list says the same, or the PR has moved on or gone.
    public func isNeeded(by row: PullRequestRow?) -> Bool {
        row.map { !$0.isAnswered && $0.head == head } ?? false
    }
}

extension PullRequestRow {
    /// This row as read, when Jai has answered the review it asks for.
    public func answered(_ answer: PRLocalAnswer?) -> PullRequestRow {
        guard let answer, isReviewRequest, let status else {
            return self
        }
        let read = Status(
            list: "reviewed", author: status.author, checks: status.checks, review: status.review, merge: status.merge,
            jaiReview: answer.review, jaiReviewedAt: answer.sentAt
        )
        return PullRequestRow(
            repo: repo, number: number, title: title, head: head, revision: revision, diff: diff, detail: detail,
            status: read, keyLines: keyLines
        )
    }
}
