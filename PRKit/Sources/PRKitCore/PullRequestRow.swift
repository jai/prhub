import Foundation

/// One row of the PRs tab, as `GET /prs` on the pr-viewer Worker answers it.
public struct PullRequestRow: Codable, Hashable, Identifiable, Sendable {
    public let repo: String
    public let number: Int
    public let title: String
    public let head: String
    public let revision: String
    public let diff: DiffAvailability
    /// The version of the description and comments. It moves with any activity on the PR.
    public let detail: String
    /// Absent only in a list saved before statuses existed. The Worker lists open PRs alone.
    public let status: Status?
    /// The context key lines are ready at for this head. Nil until they are.
    public var keyLines: Int?
    /// The Linear ticket the row shows, as Linear has it. Absent without one, and from a Worker older than it.
    public var ticket: PRListTicket?

    public init(
        repo: String, number: Int, title: String, head: String, revision: String, diff: DiffAvailability,
        detail: String, status: Status?, keyLines: Int? = nil, ticket: PRListTicket? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.head = head
        self.revision = revision
        self.diff = diff
        self.detail = detail
        self.status = status
        self.keyLines = keyLines
        self.ticket = ticket
    }

    public struct Status: Codable, Hashable, Sendable {
        public let list: String?
        public let author: String?
        public let checks: String
        public let review: String
        public let merge: String
        /// Absent in a list saved before the Worker sent them.
        public let jaiReview: String?
        public let jaiReviewedAt: String?
        /// When review was last asked of Jai himself, on the review list only. Absent from a Worker older than it.
        public var requestedAt: String?
        /// When Jai's review is due, on the review list only. Absent from a Worker older than the SLA.
        public var reviewDueAt: String?
        /// On a merged row only.
        public var mergedAt: String?

        public init(
            list: String?, author: String?, checks: String, review: String, merge: String, jaiReview: String?,
            jaiReviewedAt: String?, requestedAt: String? = nil, reviewDueAt: String? = nil, mergedAt: String? = nil
        ) {
            self.list = list
            self.author = author
            self.checks = checks
            self.review = review
            self.merge = merge
            self.jaiReview = jaiReview
            self.jaiReviewedAt = jaiReviewedAt
            self.requestedAt = requestedAt
            self.reviewDueAt = reviewDueAt
            self.mergedAt = mergedAt
        }
    }

    /// GitHub refuses a diff over 300 files or 20,000 lines.
    public enum DiffAvailability: String, Codable, Hashable, Sendable {
        case ready, pending
        case tooLarge = "too_large"
    }

    public var id: String { "\(repo)#\(number)" }
    public var hasDiff: Bool { diff != .tooLarge }
    public var isReviewRequest: Bool { status?.list == "review" }
    /// Jai answered this review. The row stays on the review list, greyed as read, until the PR closes.
    public var isAnswered: Bool { status?.list == "reviewed" }
    public var isMerged: Bool { status?.list == "merged" }
    public var reviewRequestedAt: Date? {
        isReviewRequest ? status?.requestedAt.flatMap { try? Date($0, strategy: .iso8601) } : nil
    }
    /// The Worker's due time, else one day of the phone's own working week from the request (`ReviewWeek.local`).
    public var reviewDue: Date? {
        guard isReviewRequest else {
            return nil
        }
        if let due = status?.reviewDueAt.flatMap({ try? Date($0, strategy: .iso8601) }) {
            return due
        }
        return reviewRequestedAt.flatMap { ReviewWeek.local.dueAt(requestedAt: $0) }
    }
    public func isPastSLA(now: Date) -> Bool { reviewDue.map { $0 <= now } ?? false }
    /// Asked to review again, with his own change request still holding the merge: the first thing on his list.
    public var isWaitingOnJaisChangeRequest: Bool { isReviewRequest && status?.jaiReview == "changes_requested" }
    public var org: String { String(repo.prefix { $0 != "/" }) }

    /// This PR as Agents → Lists holds one, so both screens draw it with `PrListBlock`. The Worker lists open PRs.
    public var listPullRequest: PRListPullRequest {
        typealias Marked = PullRequestStatus
        let marked = Marked(
            repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)", title: title,
            state: isMerged ? .merged : .open,
            checks: status.flatMap { Marked.Checks(rawValue: $0.checks) },
            merge: status.flatMap { Marked.Merge(rawValue: $0.merge) },
            review: status.flatMap { Marked.Review(rawValue: $0.review) }
        )
        return PRListPullRequest(
            status: marked, author: status?.author,
            jaiReview: status?.jaiReview.flatMap(PRJaiReview.init(rawValue:)),
            jaiReviewedAt: status?.jaiReviewedAt.flatMap { try? Date($0, strategy: .iso8601) },
            jaiReviewRequested: isReviewRequest, found: true, isAnswered: isAnswered, reviewDueAt: reviewDue
        )
    }

    private var fileStem: String { "\(repo.replacing("/", with: "__"))__\(number)" }
    public var diffFileName: String { "\(fileStem)__\(revision).diff" }
    public var detailFileName: String { "\(fileStem)__\(detail.replacing(":", with: "-")).json" }
    public var keyLinesFileName: String? { keyLines.map { "\(fileStem)__\(head)__keylines\($0).json" } }
}
