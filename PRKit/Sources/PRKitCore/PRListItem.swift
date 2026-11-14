import Foundation

/// One item of a list an agent sent (docs/api/lists.md §6.26): its PRs, then the agent's note, then the ticket. The
/// PRs tab makes one of these for each of its rows, so both screens draw a PR with `PrListBlock`.
public struct PRListItem: Decodable, Equatable, Sendable {
    public var ticket: PRListTicket?
    /// The tickets after `ticket`: only a PRs-tab row whose title names several has any. A list item has one ticket.
    public var moreTickets: [PRListTicket] = []
    public var pullRequests: [PRListPullRequest]
    public var title: String?
    public var note: String?

    public init(
        ticket: PRListTicket? = nil, moreTickets: [PRListTicket] = [], pullRequests: [PRListPullRequest],
        title: String? = nil, note: String? = nil
    ) {
        self.ticket = ticket
        self.moreTickets = ticket == nil ? [] : moreTickets
        self.pullRequests = pullRequests
        self.title = title
        self.note = note
    }

    /// `ticket`, then `moreTickets`: each draws its own ticket line.
    public var tickets: [PRListTicket] {
        (ticket.map { [$0] } ?? []) + moreTickets
    }

    private enum CodingKeys: String, CodingKey {
        case ticket, title, note
        case pullRequests = "prs"
    }
}

/// A Linear issue. `found` is `nil` until the hub has resolved it and `false` when Linear has no such issue for
/// the hub; only a found one has a title and a state. `url` is Linear's own once found, before that one the
/// Worker built from the workspace in the agent's Linear URL, else `nil`. A PRs-tab row carries one too
/// (`PullRequestRow.ticket`), and the phone keeps it with the row.
public struct PRListTicket: Codable, Hashable, Sendable {
    public var key: String
    public var url: String?
    public var title: String?
    public var state: String?
    public var stateType: String?
    /// The state's colour in Linear, `#5e6ad2`; `nil` from a hub that has not sent it.
    public var stateColor: String?
    public var found: Bool?
    public var resolvedAt: Date?

    public init(
        key: String, url: String? = nil, title: String? = nil, state: String? = nil, stateType: String? = nil,
        stateColor: String? = nil, found: Bool? = nil, resolvedAt: Date? = nil
    ) {
        self.key = key
        self.url = url
        self.title = title
        self.state = state
        self.stateType = stateType
        self.stateColor = stateColor
        self.found = found
        self.resolvedAt = resolvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case key, url, title, state, found
        case stateType = "state_type"
        case stateColor = "state_color"
        case resolvedAt = "resolved_at"
    }
}

/// A GitHub pull request: the ref, its URL and what GitHub said of it, held as a Threads PR (`status`) so both
/// screens put a PR's state in the same words, and Jai's own latest review of it. `found` is as for a ticket.
public struct PRListPullRequest: Equatable, Sendable {
    public var status: PullRequestStatus
    public var createdAt: Date?
    /// Who opened it: their GitHub login, and the name on their profile (`nil` for a bot or none set).
    public var author: String?
    public var authorName: String?
    public var jaiReview: PRJaiReview?
    public var jaiReviewedAt: Date?
    /// Whether a review is asked of Jai now: `true` after his review means he was asked again.
    public var jaiReviewRequested: Bool?
    public var found: Bool?
    public var resolvedAt: Date?
    /// Only the PRs tab sets this: Jai answered the review it asked of him, and the row stays, read.
    public var isAnswered: Bool?
    /// When Jai's review is due, by the review SLA: the PRs tab's row, and a list's `review_due_at`. Past it, the row
    /// says so.
    public var reviewDueAt: Date?

    public init(
        status: PullRequestStatus, createdAt: Date? = nil, author: String? = nil, authorName: String? = nil,
        jaiReview: PRJaiReview? = nil, jaiReviewedAt: Date? = nil, jaiReviewRequested: Bool? = nil, found: Bool? = nil,
        resolvedAt: Date? = nil, isAnswered: Bool? = nil, reviewDueAt: Date? = nil
    ) {
        self.status = status
        self.createdAt = createdAt
        self.author = author
        self.authorName = authorName
        self.jaiReview = jaiReview
        self.jaiReviewedAt = jaiReviewedAt
        self.jaiReviewRequested = jaiReviewRequested
        self.found = found
        self.resolvedAt = resolvedAt
        self.isAnswered = isAnswered
        self.reviewDueAt = reviewDueAt
    }

    public func pastSLA(now: Date) -> Date? { reviewDueAt.flatMap { $0 <= now ? $0 : nil } }

    /// `owner/repo#N` in lower case: how the Worker keys a ref, and how the phone remembers opening it.
    public var key: String {
        "\(status.repo.lowercased())#\(status.number)"
    }
}

/// Jai's latest review on GitHub (§6.26); `pending` is his unsubmitted draft.
public enum PRJaiReview: String, Decodable, Sendable {
    case approved
    case changesRequested = "changes_requested"
    case commented
    case dismissed
    case pending
}

extension PRListPullRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case repo, number, url, title, state, checks, merge, review, found
        case author
        case createdAt = "created_at"
        case authorName = "author_name"
        case jaiReview = "jai_review"
        case jaiReviewedAt = "jai_reviewed_at"
        case jaiReviewRequested = "jai_review_requested"
        case resolvedAt = "resolved_at"
        case reviewDueAt = "review_due_at"
    }

    /// A state word a newer Worker added reads as no state, never as a list that cannot be read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = PullRequestStatus(
            repo: try container.decode(String.self, forKey: .repo),
            number: try container.decode(Int.self, forKey: .number),
            url: try container.decode(String.self, forKey: .url),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            state: try? container.decodeIfPresent(PullRequestStatus.State.self, forKey: .state),
            checks: try? container.decodeIfPresent(PullRequestStatus.Checks.self, forKey: .checks),
            merge: try? container.decodeIfPresent(PullRequestStatus.Merge.self, forKey: .merge),
            review: try? container.decodeIfPresent(PullRequestStatus.Review.self, forKey: .review)
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        jaiReview = try? container.decodeIfPresent(PRJaiReview.self, forKey: .jaiReview)
        jaiReviewedAt = try container.decodeIfPresent(Date.self, forKey: .jaiReviewedAt)
        jaiReviewRequested = try container.decodeIfPresent(Bool.self, forKey: .jaiReviewRequested)
        found = try container.decodeIfPresent(Bool.self, forKey: .found)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        reviewDueAt = try? container.decodeIfPresent(Date.self, forKey: .reviewDueAt)
    }
}

extension PRListItem {
    /// With a ticket: its key and title, else the item's title, else the key alone — a title that starts with the
    /// key does not repeat it. Without one: the first PR's title, else the item's title, else that PR's ref.
    public var headline: String {
        if let ticket {
            guard let name = ticket.title ?? title else {
                return ticket.key
            }
            return name.hasPrefix(ticket.key) ? name : "\(ticket.key) \(name)"
        }
        guard let first = pullRequests.first else {
            return title ?? ""
        }
        return first.status.title ?? title ?? first.ref
    }
}

extension PRListItem {
    /// A PR's title, else the item's, else its ref. The ticket this block shows goes from a title that ends with it.
    public func title(of pullRequest: PRListPullRequest) -> String {
        let title = pullRequest.status.title ?? self.title ?? pullRequest.ref
        return Self.withoutShownKeys(title, shown: Set(tickets.map { $0.key.uppercased() }))
    }

    /// The title without the brackets at its end, `[ENG-1]`, `[ENG-1, ENG-2]` or `[ENG-1] [ENG-2]`, each only when every
    /// key in it has its ticket line.
    static func withoutShownKeys(_ title: String, shown: Set<String>) -> String {
        var title = Substring(title)
        while title.hasSuffix("]"), let open = title.lastIndex(of: "["), open > title.startIndex,
              title[title.index(before: open)] == " " {
            let keys = title[title.index(after: open) ..< title.index(before: title.endIndex)]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard !keys.isEmpty, keys.allSatisfy(shown.contains) else {
                break
            }
            title = title[..<title.index(before: open)]
        }
        return String(title)
    }

    /// "Aymen · web-app#6952 · 12h": who, where and how long ago. The ref stays out when it is already the title, and
    /// the age is left out until GitHub has said it.
    public func metaLine(
        of pullRequest: PRListPullRequest, now: Date, format: ThreadTimeFormat, showsAuthor: Bool
    ) -> String {
        let reference = title(of: pullRequest) == pullRequest.ref ? nil : pullRequest.status.reference
        let age = pullRequest.found == true ? pullRequest.createdAt.map { format.age($0, now: now) } : nil
        return [showsAuthor ? pullRequest.authorShortName : nil, reference, age].compactMap(\.self)
            .joined(separator: " · ")
    }
}

extension PRListTicket {
    /// Linear's word for its state, `Resolving…` until the hub has looked the issue up, `Not found` when Linear has no
    /// such issue for the hub.
    public var stateText: String {
        switch found {
        case .none: "Resolving…"
        case .some(false): "Not found"
        case .some(true): state ?? "Unknown"
        }
    }
}

/// A PR's one state: GitHub's own, or that the hub has not got it yet. Nothing here is worked out.
public enum PrListState: String, Equatable, Sendable {
    case resolving = "Resolving…"
    case notFound = "Not found"
    case open = "Open"
    case draft = "Draft"
    case merged = "Merged"
    case closed = "Closed"
}

extension PRListPullRequest {
    public var url: String {
        status.url
    }

    /// "acme/sms-sender#341": the ref as the agent wrote it.
    public var ref: String {
        "\(status.repo)#\(status.number)"
    }

    public var listState: PrListState {
        guard found == true else {
            return found == nil ? .resolving : .notFound
        }
        return switch status.state {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        case nil: .resolving
        }
    }

    /// Who opened it, shortly: the first word of the name on their GitHub profile, else their login; `nil` until the hub
    /// has looked it up.
    public var authorShortName: String? {
        authorName?.split(separator: " ").first.map(String.init) ?? author
    }

    /// The author's GitHub picture, from GitHub's own `github.com/<login>.png`; `nil` without a login, or for one a
    /// GitHub login could not be (letters, digits and hyphens).
    public var avatarURL: URL? {
        guard let author, author.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }
        return URL(string: "https://github.com/\(author).png?size=96")
    }
}

/// What Jai has done with a PR, for the line under it: his review on GitHub, else that he opened it on this device.
public struct PrJaiMark: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case approved
        case changesRequested
        case commented
        case dismissed
        case draft
        case askedAgain
        case blocking
        case opened
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

extension PRListPullRequest {
    /// His change request on an open PR: GitHub holds the merge for it until he lifts it.
    public var isBlockedByJai: Bool {
        jaiReview == .changesRequested && (status.state == .open || status.state == .draft)
    }

    /// "You're blocking · you requested changes 3m ago"; "You approved · 3m ago"; "Asked again · you commented 2d ago" when
    /// a review is asked of him after his last one; with no review, "Opened 2m ago" when he opened it here (`openedAt`),
    /// else nothing.
    public func jaiMark(openedAt: Date?, now: Date, format: ThreadTimeFormat) -> PrJaiMark? {
        let when = jaiReviewedAt.map { " · \(format.ago($0, now: now))" } ?? ""
        let submitted: (kind: PrJaiMark.Kind, did: String)? = switch jaiReview {
        case .approved: (.approved, "approved")
        case .changesRequested: (.changesRequested, "requested changes")
        case .commented: (.commented, "commented")
        case .dismissed, .pending, nil: nil
        }
        if isBlockedByJai {
            return PrJaiMark(kind: .blocking, text: "You're blocking · you requested changes\(when)")
        }
        if let submitted {
            return jaiReviewRequested == true
                ? PrJaiMark(kind: .askedAgain, text: "Asked again · you \(submitted.did)\(when)")
                : PrJaiMark(kind: submitted.kind, text: "You \(submitted.did)\(when)")
        }
        switch jaiReview {
        case .dismissed:
            return PrJaiMark(kind: .dismissed, text: "Your review was dismissed\(when)")
        case .pending:
            return PrJaiMark(kind: .draft, text: "Your review is a draft")
        default:
            return openedAt.map { PrJaiMark(kind: .opened, text: "Opened \(format.ago($0, now: now))") }
        }
    }

    /// Approved or sent back by Jai after `sent`, and not asked again since: his part of this list is done. On the PRs tab,
    /// any answer to a review he was asked for counts.
    public func isDecidedByJai(since sent: Date) -> Bool {
        if isAnswered == true {
            return true
        }
        guard let jaiReviewedAt, jaiReviewedAt > sent else {
            return false
        }
        return jaiReviewRequested != true && [.approved, .changesRequested].contains(jaiReview)
    }
}

extension PRListItem {
    /// Every PR of the item decided by Jai since the list was sent: the row fades, as a thread's does while his answer is
    /// with the agent. A new list starts at full strength, whatever he did before it, and a comment is no decision.
    public func isDecidedByJai(since sent: Date) -> Bool {
        !pullRequests.isEmpty && pullRequests.allSatisfy { $0.isDecidedByJai(since: sent) }
    }
}

/// One fact about where a PR stands, for the marks under its byline: an SF Symbol, a few words and a tone.
public struct PrStatusMark: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case good
        case bad
        case waiting
        case quiet
        case merged
    }

    public var symbol: String
    public var text: String
    public var tone: Tone

    public init(symbol: String, text: String, tone: Tone) {
        self.symbol = symbol
        self.text = text
        self.tone = tone
    }
}
