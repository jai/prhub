import Foundation

/// A comment written on this device that GitHub does not have yet. On a Worker without pending reviews it waits here
/// for the review it goes out with; otherwise it is on its way to GitHub's pending review (`sync`), and leaves the
/// device once GitHub shows it. Kept on the device until then, so it survives the app closing.
public struct PRDraftComment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let line: Int
    public let side: PRDiffSide
    public var body: String
    /// On the whole file, not on `line`: what a comment GitHub refused on its line can be sent as instead. Absent in
    /// a draft an older version stored.
    public var isFile: Bool?
    /// How its add to GitHub's pending review stands. Nil for one not sent yet: a new one, one an older version of
    /// the app stored, or one waiting for its review on a Worker without pending reviews.
    public var sync: PRDraftSync?

    public init(
        id: UUID, path: String, line: Int, side: PRDiffSide, body: String, isFile: Bool? = nil, sync: PRDraftSync? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.body = body
        self.isFile = isFile
        self.sync = sync
    }

    /// The name its add goes by while it is on its way: the outbox's id, or its own before it has one.
    public var sendKey: String {
        sync?.job ?? id.uuidString
    }

    /// Not sent yet and not refused: the next sync sends it.
    public var isUnsent: Bool {
        sync == nil
    }

    /// What is left to do once GitHub shows it as `comment`: nothing, unless it was changed or deleted here while its
    /// add could not be stopped. Then the change follows it to GitHub.
    public func changeOnceLanded(as comment: String) -> PRPendingChange? {
        if sync?.isDeleted == true {
            return PRPendingChange(comment: comment, body: nil)
        }
        if let sent = sync?.sent, sent != body {
            return PRPendingChange(comment: comment, body: body)
        }
        return nil
    }
}

/// A device comment's add to GitHub's pending review, from the moment it is handed to the write path.
public struct PRDraftSync: Codable, Hashable, Sendable {
    /// The outbox's id for the add, once saved there: its answer or refusal finds the comment by it, after a
    /// relaunch too.
    public var job: String?
    /// The words the add carries. The comment's own can change while it is on its way.
    public var sent: String?
    /// Deleted here while its add could not be stopped: it is removed from GitHub once it lands.
    public var isDeleted: Bool?
    /// GitHub's refusal, in its words. It stays until the comment is tried again or deleted.
    public var failure: String?

    public init(job: String? = nil, sent: String? = nil, isDeleted: Bool? = nil, failure: String? = nil) {
        self.job = job
        self.sent = sent
        self.isDeleted = isDeleted
        self.failure = failure
    }
}

/// One file per PR, in Application Support: a draft is Jai's words, so iOS clearing a cache must not take it. Beside
/// it, a file of the changes to comments GitHub holds (`PRPendingChange`), and one file naming the PR each outbox job
/// belongs to, so an answer that comes after a relaunch finds its comment.
public struct PRDraftStore: Sendable {
    let store: any PRFileStore
    private static let jobsFile = "pending-jobs.json"

    public init(store: any PRFileStore) {
        self.store = store
    }

    public init(directory: URL = Self.defaultDirectory) {
        self.init(store: PRDiskFileStore(directory: directory))
    }

    /// Application Support's `pr-drafts`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "pr-drafts", directoryHint: .isDirectory)
    }

    private func file(_ ref: PullRequestRef, suffix: String = "") -> String {
        "\(ref.repo.replacing("/", with: "__"))__\(ref.number)\(suffix).json"
    }

    public func load(_ ref: PullRequestRef) -> [PRDraftComment] {
        store.read(file(ref)).flatMap { try? JSONDecoder().decode([PRDraftComment].self, from: $0) } ?? []
    }

    public func save(_ drafts: [PRDraftComment], for ref: PullRequestRef) {
        if drafts.isEmpty {
            store.remove(file(ref))
        } else if let data = try? JSONEncoder().encode(drafts) {
            try? store.write(data, to: file(ref))
        }
    }

    /// Everything the device holds of the PR's pending review: its own comments, and its changes to GitHub's.
    public func loadPending(_ ref: PullRequestRef) -> PRPendingDevice {
        let changes = store.read(file(ref, suffix: ".changes"))
            .flatMap { try? JSONDecoder().decode([PRPendingChange].self, from: $0) } ?? []
        return PRPendingDevice(drafts: load(ref), changes: changes)
    }

    public func save(_ pending: PRPendingDevice, for ref: PullRequestRef) {
        save(pending.drafts, for: ref)
        if pending.changes.isEmpty {
            store.remove(file(ref, suffix: ".changes"))
        } else if let data = try? JSONEncoder().encode(pending.changes) {
            try? store.write(data, to: file(ref, suffix: ".changes"))
        }
    }

    private struct JobOwner: Codable {
        let repo: String
        let number: Int
    }

    private func jobs() -> [String: JobOwner] {
        store.read(Self.jobsFile).flatMap { try? JSONDecoder().decode([String: JobOwner].self, from: $0) } ?? [:]
    }

    /// The PR whose pending comment or change the outbox job `job` carries; nil for any other job.
    public func owner(ofJob job: String) -> PullRequestRef? {
        jobs()[job].map { PullRequestRef(repo: $0.repo, number: $0.number) }
    }

    /// `ref` set names the job's PR; nil forgets the job, once it is answered, refused or stopped.
    public func setOwner(_ ref: PullRequestRef?, ofJob job: String) {
        var jobs = jobs()
        jobs[job] = ref.map { JobOwner(repo: $0.repo, number: $0.number) }
        if jobs.isEmpty {
            store.remove(Self.jobsFile)
        } else if let data = try? JSONEncoder().encode(jobs) {
            try? store.write(data, to: Self.jobsFile)
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

public extension PullRequestRow {
    /// This row as read, when Jai has answered the review it asks for.
    func answered(_ answer: PRLocalAnswer?) -> PullRequestRow {
        guard let answer, isReviewRequest, let status else {
            return self
        }
        let read = Status(
            list: "reviewed", author: status.author, checks: status.checks, review: status.review, merge: status.merge,
            jaiReview: answer.review, jaiReviewedAt: answer.sentAt, requestedBy: status.requestedBy, agent: status.agent
        )
        return with(read)
    }
}
