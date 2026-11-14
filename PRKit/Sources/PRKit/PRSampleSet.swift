import PRKitCore
import PRKitDesign
import Foundation

/// PRs with no Worker behind them: each row with its description, diff and key lines, written where the mirror would
/// have put them. Jai's Debug `-UXFixtures` has one (`UXFixtures+PRs.swift`), and so does PRHub's "Try with sample PRs"
/// (`PRHubSamples.swift`). A model holding samples sends nothing: it syncs, reads and asks the model for nothing.
public struct PRSampleSet: Sendable {
    /// One sample PR, as the mirror would hold it.
    public struct Sample: Sendable {
        public let row: PullRequestRow
        /// `PullRequestDetail` JSON.
        public let detail: String
        public let diff: String
        /// `PRKeyLines` JSON, at `row.keyLines`'s context.
        public let keyLines: String?

        public init(row: PullRequestRow, detail: String, diff: String, keyLines: String?) {
            self.row = row
            self.detail = detail
            self.diff = diff
            self.keyLines = keyLines
        }
    }

    public let samples: [Sample]
    /// Merged rows: those reviewed (For review), and the user's own (My PRs).
    public let mergedReviewed: [PullRequestRow]
    public let mergedMine: [PullRequestRow]
    /// A write answers from the phone, with the PR as it would stand, and says that nothing reached GitHub; key lines
    /// are the sample's own at any context. Otherwise both are refused: Jai's fixture rows name real PRs.
    public let answersOnPhone: Bool
    /// Every sample PR's Ask AI conversation; none when nil.
    public var askChat: PRAskChat?
    /// How long a review sent from its box takes to answer, as a Worker's would: long enough to see it go.
    public var reviewDelay = Duration.milliseconds(900)
    /// Set, the first review sent from its box is refused in these words, and Retry sends it: a UI test's or a
    /// recording's way to show a refusal on sample PRs.
    public var refusesFirstReview: String?
    /// Set, the list opens with these words in its "Not up to date" line: a UI test's way to picture that line.
    public var notUpToDate: String?
    /// How long a pull to refresh takes. Samples answer at once; a UI test sets it to picture the list refreshing.
    public var refreshDelay = Duration.zero

    public init(
        samples: [Sample], mergedReviewed: [PullRequestRow], mergedMine: [PullRequestRow], answersOnPhone: Bool
    ) {
        self.samples = samples
        self.mergedReviewed = mergedReviewed
        self.mergedMine = mergedMine
        self.answersOnPhone = answersOnPhone
    }

    /// Apart from the mirror's own directory, so samples never mix with a Worker's PRs.
    public static let directoryName = "pr-samples"
    /// Said under a PR's actions after a write that stayed on the phone.
    public static let notice = "Sample PR: this stays on your phone. Nothing was sent to GitHub."
    /// The list's own saved settings. A sample's orgs must not become the filter of the Worker connected next.
    public static let listSettingKeys = ["prOrgFilter", "prListPage", "prShowsMerged", "prShowsMergedReviews"]

    public var rows: [PullRequestRow] {
        samples.map(\.row)
    }

    /// The sample's key lines, when its set answers on the phone.
    public func keyLines(for ref: PullRequestRef) -> Data? {
        guard answersOnPhone else {
            return nil
        }
        return samples.first { $0.row.repo == ref.repo && $0.row.number == ref.number }?.keyLines.map { Data($0.utf8) }
    }

    public func merged(reviewed: Bool) -> [PullRequestRow] {
        reviewed ? mergedReviewed : mergedMine
    }

    /// Writes every sample's files into `directory` and starts the list with no saved settings.
    public func seed(in directory: URL) -> [PullRequestRow] {
        Self.resetListSettings()
        for sample in samples {
            try? Data(sample.detail.utf8).write(to: directory.appending(path: sample.row.detailFileName))
            try? Data(sample.diff.utf8).write(to: directory.appending(path: sample.row.diffFileName))
            if let name = sample.row.keyLinesFileName, let keyLines = sample.keyLines {
                try? Data(keyLines.utf8).write(to: directory.appending(path: name))
            }
        }
        return rows
    }

    public static func resetListSettings(_ defaults: UserDefaults = .standard) {
        for key in listSettingKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// The stored detail with `write` applied as GitHub would show it, signed by `login`. A review or a comment joins
    /// the conversation; an approval or a change request is the decision and its reviewer's state; a line comment,
    /// alone or sent with a review, starts a thread on its line, which takes replies and resolves; an edit is the
    /// description; a merge leaves the PR merged. Other writes leave it as it was.
    public static func applying(_ write: PRWrite, to detail: Data, login: String, now: Date = .now) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: detail)) as? [String: Any] else {
            return detail
        }
        let author: [String: Any] = ["login": login, "avatarUrl": NSNull()]
        let stamp = now.ISO8601Format()
        let id = { "sample-\(UUID().uuidString)" }
        let comment = { (body: String) -> [String: Any] in
            ["id": id(), "author": author, "body": body, "createdAt": stamp]
        }
        let newThread = { (path: String, line: Int, side: PRDiffSide, body: String) -> [String: Any] in
            [
                "id": id(), "isResolved": false, "isOutdated": false, "viewerCanResolve": true,
                "viewerCanUnresolve": true, "path": path, "line": line, "diffSide": side.rawValue,
                "comments": ["nodes": [comment(body)]],
            ]
        }
        switch write {
        case let .review(event, body, _, comments):
            object.append(
                [["id": id(), "author": author, "state": event.state, "body": body, "submittedAt": stamp]],
                to: "reviews"
            )
            object.append(comments.map { newThread($0.path, $0.line, $0.side, $0.body) }, to: "reviewThreads")
            if event != .comment {
                object["reviewDecision"] = event.state
                let mine: [String: Any] = ["login": login, "avatarUrl": NSNull(), "state": event.state]
                let others = (object["reviewers"] as? [[String: Any]] ?? []).filter { $0["login"] as? String != login }
                object["reviewers"] = others + [mine]
            }
        case let .comment(body):
            object.append([comment(body)], to: "comments")
        case let .line(path, line, side, body, _):
            object.append([newThread(path, line, side, body)], to: "reviewThreads")
        case let .reply(thread, body):
            object.changeThread(thread) { $0.append([comment(body)], to: "comments") }
        case let .resolve(thread, resolved):
            object.changeThread(thread) { $0["isResolved"] = resolved }
        case let .editBody(body, _):
            object["body"] = body
        case .merge:
            object["state"] = "merged"
        default:
            return detail
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? detail
    }

    /// A sample's row after `write`, as the Worker's next list would have it: an approval or a change request is the
    /// PR's review. Other writes leave the row as it was; a merge takes it off the open list (`PRsModel`).
    public static func applying(_ write: PRWrite, to row: PullRequestRow) -> PullRequestRow {
        guard case let .review(event, _, _, _) = write, event != .comment, let status = row.status else {
            return row
        }
        return row.with(status.with(review: event == .approve ? "approved" : "changes_requested"))
    }
}

private extension [String: Any] {
    /// Adds `items` to the `nodes` under `key`, as the detail holds its comments, reviews and threads.
    mutating func append(_ items: [[String: Any]], to key: String) {
        var holder = self[key] as? [String: Any] ?? [:]
        holder["nodes"] = (holder["nodes"] as? [Any] ?? []) + items
        self[key] = holder
    }

    /// Changes the review thread with this id, where the detail has it.
    mutating func changeThread(_ id: String, _ change: (inout [String: Any]) -> Void) {
        var holder = self["reviewThreads"] as? [String: Any] ?? [:]
        holder["nodes"] = (holder["nodes"] as? [[String: Any]] ?? []).map { thread in
            guard thread["id"] as? String == id else {
                return thread
            }
            var changed = thread
            change(&changed)
            return changed
        }
        self["reviewThreads"] = holder
    }
}

private extension PRReviewEvent {
    /// GitHub's state for a review sent with this event.
    var state: String {
        switch self {
        case .approve: "APPROVED"
        case .requestChanges: "CHANGES_REQUESTED"
        case .comment: "COMMENTED"
        }
    }
}

extension PRViewerAccess {
    /// No Worker: every request fails as `notPaired` before anything is sent. The sample PRs' client.
    public static let offline = PRViewerAccess(baseURL: { nil }, bearer: { "" }, discard: {})
}
