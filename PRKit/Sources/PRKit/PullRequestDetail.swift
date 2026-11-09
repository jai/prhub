import PRKitCore
import PRKitDesign
import Foundation

/// A PR's description, status and conversation, as the Worker stores them (`Detail` in worker/src/github.ts).
public struct PullRequestDetail: Decodable, Sendable {
    public struct Nodes<Item: Decodable & Sendable>: Decodable, Sendable {
        public let nodes: [Item]
    }

    public struct Author: Decodable, Sendable {
        public let login: String
        public let avatarUrl: String?
    }

    public struct Comment: Decodable, Identifiable, Sendable {
        public let id: String
        public let author: Author?
        public let body: String
        public let createdAt: Date
    }

    public struct Review: Decodable, Identifiable, Sendable {
        public let id: String
        public let author: Author?
        public let state: String
        public let body: String
        public let submittedAt: Date?
    }

    public struct Thread: Decodable, Identifiable, Sendable {
        public let id: String
        public let isResolved: Bool
        /// Absent in a detail stored before these were read.
        public let isOutdated: Bool?
        public let viewerCanResolve: Bool?
        public let viewerCanUnresolve: Bool?
        public let path: String
        public let line: Int?
        public let diffSide: String
        public let comments: Nodes<Comment>
    }

    public struct Label: Decodable, Identifiable, Sendable {
        public let name: String
        public let color: String

        public var id: String { name }
    }

    public struct Check: Decodable, Identifiable, Sendable {
        public let name: String
        public let state: String
        public let url: String?
        /// GitHub holds the merge for this check. Absent in a detail saved before the Worker said.
        public let required: Bool?
        /// The Actions workflow that ran it: null for a commit status, absent in a detail saved before the Worker said.
        public var workflow: String?

        public var id: String { "\(workflow ?? "")\n\(name)\(url ?? "")" }
    }

    /// PolicyBot's status on the head, where the repo uses it: the real gate, not GitHub's `reviewDecision`.
    public struct Policy: Decodable, Sendable {
        public let state: String
        public let description: String?
        public let url: String?
        /// GitHub holds the merge for it. Absent in a detail saved before the Worker said; repos that require it.
        public let required: Bool?

        /// As a line in the checks.
        public var check: Check {
            let states = ["approved": "success", "disapproved": "failure"]
            return Check(name: "PolicyBot", state: states[state] ?? "pending", url: url, required: required ?? true)
        }
    }

    /// The checks as the PR shows them: PolicyBot among the rest, since GitHub requires it like any other. Required first,
    /// then what needs looking at, then by name.
    public var listedChecks: [Check] {
        let rank = ["failure": 0, "pending": 1, "success": 2, "skipped": 3]
        return ((policy.map { [$0.check] } ?? []) + checks).sorted { first, second in
            let order = { (check: Check) in (check.required == false ? 1 : 0, rank[check.state] ?? 3) }
            return order(first) != order(second)
                ? order(first) < order(second)
                : first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
    }
    private var knowsRequired: Bool { checks.contains { $0.required != nil } }

    /// The checks that decide anything: the required ones. A detail saved before the Worker said has only all.
    public var decidingChecks: [Check] {
        knowsRequired || checks.isEmpty ? listedChecks.filter { $0.required != false } : listedChecks
    }

    /// "1/3 required checks pass".
    public var checksSummary: String {
        let total = decidingChecks.count
        guard total > 0 else {
            return "No required checks"
        }
        let passing = decidingChecks.filter { $0.state == "success" }.count
        return "\(passing)/\(total) \(knowsRequired || checks.isEmpty ? "required checks" : "checks") pass"
    }

    public struct Reviewer: Decodable, Identifiable, Sendable {
        public let login: String
        public let avatarUrl: String?
        public let state: String

        public var id: String { login }
    }

    /// Absent only in a sample detail. GitHub's own id, which marking a file viewed needs.
    public let id: String?
    public let url: String
    /// GitHub's state. Absent in a detail stored before it was read; stored ones are PRs on Jai's lists, which are open.
    public let state: String?
    public let head: String
    public let base: String
    public let headBranch: String
    public let author: Author?
    public let isAuthor: Bool
    public let body: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let reviewDecision: String?
    public let mergeState: String
    /// These four are absent in a detail stored before they were read.
    public let mergeMethod: String?
    public let policy: Policy?
    public let reviewers: [Reviewer]?
    public let viewedFiles: [String]?
    public let labels: [Label]
    public let checks: [Check]
    public let comments: Nodes<Comment>
    public let reviews: Nodes<Review>
    public let reviewThreads: Nodes<Thread>
    /// Present only on a live read: the Worker's rows carry the title otherwise.
    public let title: String?

    public var listState: PrListState {
        PrListState(rawValue: (state ?? "open").capitalized) ?? .open
    }

    public static func decode(_ data: Data) throws -> PullRequestDetail {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: data)
    }

    /// One thing said on the PR, in the order it was said. A review that says nothing but carries inline comments has
    /// no entry of its own: its comments are in their threads.
    public enum Entry: Identifiable, Sendable {
        case comment(Comment)
        case review(Review)
        case thread(Thread)

        public var id: String {
            switch self {
            case let .comment(comment): comment.id
            case let .review(review): review.id
            case let .thread(thread): thread.id
            }
        }

        fileprivate var date: Date {
            switch self {
            case let .comment(comment): comment.createdAt
            case let .review(review): review.submittedAt ?? .distantPast
            case let .thread(thread): thread.comments.nodes.first?.createdAt ?? .distantPast
            }
        }
    }

    public var conversation: [Entry] {
        let spoken = comments.nodes.map(Entry.comment)
        let reviewed = reviews.nodes.filter { !($0.state == "COMMENTED" && $0.body.isEmpty) }.map(Entry.review)
        return (spoken + reviewed + reviewThreads.nodes.map(Entry.thread)).sorted { $0.date < $1.date }
    }
}

/// GitHub's Markdown is full of what only a web page draws: HTML comments from PR templates, badges and bots' tags.
public enum PRMarkdown {
    /// The words of the task at `index`, counted as the pr-viewer Worker counts them (`toggleTask`): none inside an HTML
    /// comment or a code fence.
    public static func taskText(in body: String, at index: Int) -> String? {
        let task = /^(\s*[-*] \[)[ xX](\] )/
        var seen = 0
        var inFence = false
        var inComment = false
        for line in body.components(separatedBy: "\n") {
            if inComment {
                inComment = !line.contains("-->")
            } else if let open = line.range(of: "<!--") {
                inComment = !line[open.lowerBound...].contains("-->")
            } else if line.wholeMatch(of: /\s*```.*/) != nil {
                inFence.toggle()
            } else if !inFence, let match = line.prefixMatch(of: task) {
                if seen == index {
                    return String(line[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                seen += 1
            }
        }
        return nil
    }

    private static let webOnlyTags = """
    details|summary|br|sub|sup|p|div|img|picture|source|a|b|i|em|strong|span|kbd|hr|ul|ol|li|h[1-6]|\
    table|tr|td|th|tbody|thead|relative-time
    """

    public static func clean(_ source: String) -> String {
        var text = source
        let rules: [(String, String)] = [
            (#"(?s)<!--.*?-->"#, ""),
            (#"\[!\[([^\]]*)\]\([^)]*\)\]\(([^)]*)\)"#, "[$1]($2)"),
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            ("(?i)</?(\(webOnlyTags))\\b[^>]*>", ""),
            (#"(?m)^(\s*[-*]) \[[xX]\] "#, "$1 ☑︎ "),
            (#"(?m)^(\s*[-*]) \[ \] "#, "$1 ☐ "),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
