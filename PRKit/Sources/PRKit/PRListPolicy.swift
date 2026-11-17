import Foundation
import PRKitCore

/// The two lists the PRs tab holds.
enum PRListPage: String, CaseIterable, Identifiable {
    case review, mine

    var id: Self {
        self
    }

    func holds(_ row: PullRequestRow) -> Bool {
        (row.isReviewRequest || row.isAnswered) == (self == .review)
    }

    /// A line of the list. On the review list, what Jai still has to review, then what he has approved, sent back or
    /// commented on.
    enum Entry: Identifiable {
        case header(String)
        case row(PullRequestRow)

        var id: String {
            switch self {
            case let .header(title): "header:\(title)"
            case let .row(row): row.id
            }
        }
    }

    /// `grouping` puts a header over each repo's or author's rows, in the order their first row comes. On the review
    /// list the groups hold what Jai still has to review, and Recently Reviewed stays one section under them.
    func entries(_ rows: [PullRequestRow], grouping: PRListGrouping = .none) -> [Entry] {
        let section = { (title: String, rows: [PullRequestRow]) -> [Entry] in
            rows.isEmpty ? [] : [.header(title)] + rows.map(Entry.row)
        }
        let grouped = { (rows: [PullRequestRow]) -> [Entry] in
            guard let key = grouping.key else {
                return rows.map(Entry.row)
            }
            var names: [String] = []
            var groups: [String: [PullRequestRow]] = [:]
            for row in rows {
                let name = key(row)
                if groups[name] == nil {
                    names.append(name)
                }
                groups[name, default: []].append(row)
            }
            return names.flatMap { section($0, groups[$0] ?? []) }
        }
        guard self == .review, !rows.contains(where: \.isMerged) else {
            return grouped(rows)
        }
        let pending = rows.filter { !$0.isAnswered }
        return (grouping == .none ? section("Review Pending", pending) : grouped(pending))
            + section("Recently Reviewed", rows.filter(\.isAnswered))
    }

    /// `.sla`: past the review SLA first, the longest overdue on top; then the rows waiting on Jai's own change
    /// request; then the rest, the longest waiting first. `.oldest` and `.newest` go by when review was asked alone.
    /// Rows with no request time (My PRs, Recently Reviewed) keep the order they came in, after the rest.
    static func ordered(_ rows: [PullRequestRow], by order: PRListOrder = .sla, now: Date = .now) -> [PullRequestRow] {
        switch order {
        case .sla:
            let late = rows.filter { $0.isPastSLA(now: now) }.sorted { ($0.reviewDue ?? now) < ($1.reviewDue ?? now) }
            let rest = byAge(rows.filter { !$0.isPastSLA(now: now) }, newestFirst: false)
            return late + rest.filter(\.isWaitingOnJaisChangeRequest) + rest.filter { !$0.isWaitingOnJaisChangeRequest }
        case .oldest:
            return byAge(rows, newestFirst: false)
        case .newest:
            return byAge(rows, newestFirst: true)
        }
    }

    private static func byAge(_ rows: [PullRequestRow], newestFirst: Bool) -> [PullRequestRow] {
        rows.enumerated().sorted { first, second in
            switch (first.element.reviewRequestedAt, second.element.reviewRequestedAt) {
            case let (one?, two?) where one != two: newestFirst ? one > two : one < two
            case (.some, nil): true
            case (nil, .some): false
            default: first.offset < second.offset
            }
        }.map(\.element)
    }
}

/// How a page of the PRs tab is ordered, saved on the phone.
enum PRListOrder: String, CaseIterable, Identifiable {
    case sla, oldest, newest

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .sla: "Past SLA, then oldest"
        case .oldest: "Oldest request first"
        case .newest: "Newest request first"
        }
    }
}

/// What a page of the PRs tab is grouped under, saved on the phone.
enum PRListGrouping: String, CaseIterable, Identifiable {
    case none, repo, author

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .none: "No groups"
        case .repo: "Repo"
        case .author: "Author"
        }
    }

    var key: ((PullRequestRow) -> String)? {
        switch self {
        case .none: nil
        case .repo: { $0.repo }
        case .author: { $0.status?.author ?? "Unknown author" }
        }
    }
}

/// The orgs and repos the PRs tab shows, saved on the phone. Every org's PRs are mirrored either way, so a change is
/// instant and nothing has to load.
struct PROrgFilter: RawRepresentable, Equatable {
    private(set) var selected: Set<String>
    /// Empty means every repo of the chosen orgs.
    private(set) var repos: Set<String> = []

    init(selected: Set<String>) {
        self.selected = selected
    }

    /// `orgs|repos`, each comma separated. A value saved before repos existed has no `|`.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        selected = Set(parts[0].split(separator: ",").map(String.init))
        repos = parts.count > 1 ? Set(parts[1].split(separator: ",").map(String.init)) : []
    }

    var rawValue: String {
        "\(selected.sorted().joined(separator: ","))|\(repos.sorted().joined(separator: ","))"
    }

    func showsOrg(of row: PullRequestRow) -> Bool {
        selected.contains(row.org)
    }

    func shows(_ row: PullRequestRow) -> Bool {
        showsOrg(of: row) && (repos.isEmpty || repos.contains(row.repo))
    }

    /// An org going takes its repos with it, so a hidden choice can't empty the list.
    mutating func toggle(_ org: String) {
        if selected.remove(org) == nil {
            selected.insert(org)
        } else {
            repos = repos.filter { !$0.hasPrefix("\(org)/") }
        }
    }

    mutating func toggleRepo(_ repo: String) {
        if repos.remove(repo) == nil {
            repos.insert(repo)
        }
    }

    mutating func showAllRepos() {
        repos = []
    }
}
