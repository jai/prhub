import Foundation

/// A GitHub pull request. Its state fields are `nil` when GitHub did not answer the hub, and `merge` is `nil` once
/// it is merged or closed.
public struct PullRequestStatus: Decodable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var url: String
    public var title: String?
    public var state: State?
    public var checks: Checks?
    public var merge: Merge?
    public var review: Review?
    /// Who opened it: their GitHub login, and the name on their profile. `nil` until the hub has looked it up.
    public var author: String?
    public var authorName: String?

    public init(
        repo: String, number: Int, url: String, title: String? = nil, state: State? = nil, checks: Checks? = nil,
        merge: Merge? = nil, review: Review? = nil, author: String? = nil, authorName: String? = nil
    ) {
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.checks = checks
        self.merge = merge
        self.review = review
        self.author = author
        self.authorName = authorName
    }

    private enum CodingKeys: String, CodingKey {
        case repo, number, url, title, state, checks, merge, review, author
        case authorName = "author_name"
    }

    public enum State: String, Decodable, Sendable {
        case open, draft, merged, closed
    }

    public enum Checks: String, Decodable, Sendable {
        case passing, failing, pending
        case noChecks = "none"
    }

    public enum Merge: String, Decodable, Sendable {
        case clean, behind, blocked, conflicting, unstable, unknown
    }

    public enum Review: String, Decodable, Sendable {
        case approved
        case changesRequested = "changes_requested"
        case required
        case noReview = "none"
    }
}

extension PullRequestStatus {
    /// This PR as a list holds one, so that it is drawn with the list's parts.
    public var listPullRequest: PRListPullRequest {
        PRListPullRequest(status: self, author: author, authorName: authorName, found: true)
    }

    /// "web-app#6743": the repository's name without its owner, and the number.
    public var reference: String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)"
    }

    /// "merged", or for an open PR what stands between it and a merge: "open, checks failing, behind".
    public var statusText: String {
        guard let state else {
            return "unknown"
        }
        guard state == .open || state == .draft else {
            return state.rawValue
        }
        let details = [checks?.phrase, merge?.phrase, review?.phrase].compactMap(\.self)
        return ([state.rawValue] + details).joined(separator: ", ")
    }
}

extension PullRequestStatus.Checks {
    public var phrase: String? {
        switch self {
        case .passing: "checks passing"
        case .failing: "checks failing"
        case .pending: "checks pending"
        case .noChecks: nil
        }
    }
}

extension PullRequestStatus.Merge {
    public var phrase: String? {
        switch self {
        case .behind: "behind"
        case .blocked: "blocked"
        case .conflicting: "conflicts"
        case .unstable: "unstable"
        case .clean, .unknown: nil
        }
    }
}

extension PullRequestStatus.Review {
    public var phrase: String? {
        switch self {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .required: "review required"
        case .noReview: nil
        }
    }
}
