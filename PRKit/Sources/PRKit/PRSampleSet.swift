import Foundation
import PRKitCore
import PRKitDesign

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
        /// Each changed file's text at the PR's head, by path: what the diff's hunks leave out is read from it.
        public let files: [String: String]

        public init(row: PullRequestRow, detail: String, diff: String, keyLines: String?, files: [String: String] = [:]) {
            self.row = row
            self.detail = detail
            self.diff = diff
            self.keyLines = keyLines
            self.files = files
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
    /// How long a landed review's toast stays before it goes; nil is the app's own time (`ToastStyle.dwell`). A UI test
    /// sets it long: it reads the toast's words by polling, and one poll can take longer than the toast's 2 seconds.
    public var reviewDwell: Duration?
    /// Set, the first review sent from its box is refused in these words, and Retry sends it: a UI test's or a
    /// recording's way to show a refusal on sample PRs.
    public var refusesFirstReview: String?
    /// Set, a sample's pending comment on a line is refused in these words, as GitHub refuses one on a line outside the
    /// diff; one on a whole file is taken. A UI test's way to show a pending comment that failed.
    public var refusesLinePendingAdds: String?
    /// The labels every sample PR's repo has, and whether they can be put on a PR: what a sample answers the labels
    /// read with.
    public var repoLabels = PRRepoLabels(labels: PRSampleSet.sampleLabels, canEdit: true)
    /// The files, by path, whose text can't be read, and why: a UI test's way to show a read that failed.
    public var failsFileReads: [String: PRFileProblem] = [:]
    /// Set, the list opens with these words in its "Not up to date" line: a UI test's way to picture that line.
    public var notUpToDate: String?

    public init(
        samples: [Sample], mergedReviewed: [PullRequestRow], mergedMine: [PullRequestRow], answersOnPhone: Bool
    ) {
        self.samples = samples
        self.mergedReviewed = mergedReviewed
        self.mergedMine = mergedMine
        self.answersOnPhone = answersOnPhone
    }

    /// A made-up repo's labels, sorted as the Worker sends them. "sample" is the one PRHub's sample PRs come with.
    public static let sampleLabels: [PRRepoLabels.Label] = [
        .init(name: "bug", color: "d73a4a", description: "Something isn't working"),
        .init(name: "documentation", color: "0075ca", description: "Improvements or additions to the docs"),
        .init(name: "enhancement", color: "a2eeef", description: "A new feature or request"),
        .init(name: "help-wanted", color: "008672", description: "Extra attention is needed"),
        .init(name: "needs-design", color: "fbca04", description: "Waiting on a design before it can go on"),
        .init(name: "question", color: "d876e3", description: nil),
        .init(name: "sample", color: "8250DF", description: "A PR that comes with the app"),
        .init(name: "wontfix", color: "ffffff", description: "This will not be worked on"),
    ]

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

    /// A sample file's text at its PR's head, as the Worker's `file` route answers: the sample's own, or the problem
    /// `failsFileReads` names. A file the sample has no text for is not there.
    public func fileText(_ path: String, for ref: PullRequestRef) throws -> Data {
        if let problem = failsFileReads[path] {
            throw problem
        }
        guard let text = samples.first(where: { $0.row.repo == ref.repo && $0.row.number == ref.number })?.files[path]
        else {
            throw PRFileProblem.missing
        }
        return Data(text.utf8)
    }

    public func merged(reviewed: Bool) -> [PullRequestRow] {
        reviewed ? mergedReviewed : mergedMine
    }

    /// Writes every sample's files into `files` and starts the list with no saved settings.
    public func seed(in files: any PRFileStore, settings: any PRKeyValueStore) -> [PullRequestRow] {
        Self.resetListSettings(settings)
        for sample in samples {
            try? files.write(Data(sample.detail.utf8), to: sample.row.detailFileName)
            try? files.write(Data(sample.diff.utf8), to: sample.row.diffFileName)
            if let name = sample.row.keyLinesFileName, let keyLines = sample.keyLines {
                try? files.write(Data(keyLines.utf8), to: name)
            }
        }
        return rows
    }

    /// `seed(in:settings:)` on disk.
    public func seed(in directory: URL, defaults: UserDefaults = .standard) -> [PullRequestRow] {
        seed(in: PRDiskFileStore(directory: directory), settings: defaults)
    }

    public static func resetListSettings(_ settings: any PRKeyValueStore = UserDefaults.standard) {
        for key in listSettingKeys {
            settings.removeObject(forKey: key)
        }
    }

    /// The stored detail with `write` applied as GitHub would show it, signed by `login`. A review or a comment joins
    /// the conversation; an approval or a change request is the decision and its reviewer's state; a line comment,
    /// alone or sent with a review, starts a thread on its line, which takes replies and resolves; an edit is the
    /// description; a merge leaves the PR merged. A detail that carries `pendingReview` keeps a pending review as
    /// GitHub would: comments are added to it, changed and removed, and its submit posts them with the review. A label
    /// is put on in its colour among `labels`, the repo's, or taken off. Other writes leave it as it was.
    public static func applying(
        _ write: PRWrite, to detail: Data, login: String, now: Date = .now, labels: [PRRepoLabels.Label] = []
    ) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: detail)) as? [String: Any] else {
            return detail
        }
        if let pending = applyingPending(write, to: object, login: login, now: now) {
            return (try? JSONSerialization.data(withJSONObject: pending)) ?? detail
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
        case let .labelAdd(name):
            let held = object["labels"] as? [[String: Any]] ?? []
            if !held.contains(where: { $0["name"] as? String == name }) {
                let color = labels.first { $0.name == name }?.color ?? "808080"
                object["labels"] = held + [["name": name, "color": color]]
            }
        case let .labelRemove(name):
            object["labels"] = (object["labels"] as? [[String: Any]] ?? []).filter { $0["name"] as? String != name }
        default:
            return detail
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? detail
    }

    /// `detail` after a write to its pending review; nil for any other write. A detail without the `pendingReview`
    /// key is an older Worker's, and stays as it was.
    private static func applyingPending(
        _ write: PRWrite, to detail: [String: Any], login: String, now: Date
    ) -> [String: Any]? {
        var object = detail
        switch write {
        case let .pendingAdd(_, path, line, side, body):
            let added: [String: Any] = [
                "id": "sample-\(UUID().uuidString)", "path": path, "line": line ?? NSNull(), "side": side.rawValue,
                "body": body, "createdAt": now.ISO8601Format(), "outdated": false, "thread": NSNull(),
                "file": line == nil,
            ]
            object.changePending { $0 + [added] }
        case let .pendingEdit(comment, body):
            object.changePending { comments in
                comments.map { $0["id"] as? String == comment ? $0.merging(["body": body]) { _, new in new } : $0 }
            }
        case let .pendingDelete(comment):
            object.changePending { comments in comments.filter { $0["id"] as? String != comment } }
        case let .pendingSubmit(event, body):
            return submittingPending(event, body: body, in: object, login: login, now: now)
        case .pendingDiscard:
            if object["pendingReview"] != nil {
                object["pendingReview"] = NSNull()
            }
        default:
            return nil
        }
        return object
    }

    /// The review posted with every pending comment: a reply joins its thread, the rest each start one, on their
    /// line or, with none, on their file.
    private static func submittingPending(
        _ event: PRReviewEvent, body: String, in detail: [String: Any], login: String, now: Date
    ) -> [String: Any] {
        var object = detail
        let comments = object.pendingComments
        if object["pendingReview"] != nil {
            object["pendingReview"] = NSNull()
        }
        let review = PRWrite.review(event, body: body, commit: "", comments: [])
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let posted = try? JSONSerialization.jsonObject(with: applying(review, to: data, login: login, now: now))
        {
            object = posted as? [String: Any] ?? object
        }
        for pending in comments {
            let said: [String: Any] = [
                "id": "sample-\(UUID().uuidString)", "author": ["login": login, "avatarUrl": NSNull()],
                "body": pending["body"] as? String ?? "", "createdAt": now.ISO8601Format(),
            ]
            if let thread = pending["thread"] as? String {
                object.changeThread(thread) { $0.append([said], to: "comments") }
            } else {
                object.append([[
                    "id": "sample-\(UUID().uuidString)", "isResolved": false, "isOutdated": false,
                    "viewerCanResolve": true, "viewerCanUnresolve": true, "path": pending["path"] as? String ?? "",
                    "line": pending["line"] ?? NSNull(), "diffSide": pending["side"] as? String ?? "RIGHT",
                    "comments": ["nodes": [said]],
                ]], to: "reviewThreads")
            }
        }
        return object
    }

    /// Why a sample refuses to change a label, in the words GitHub's refusal comes in; nil when it takes the change.
    public func labelRefusal(of write: PRWrite) -> String? {
        let name: String
        switch write {
        case let .labelAdd(added): name = added
        case let .labelRemove(removed): name = removed
        default: return nil
        }
        guard repoLabels.canEdit else {
            return "You can't change labels on this repo."
        }
        if case .labelAdd = write, !repoLabels.labels.contains(where: { $0.name == name }) {
            return "This repo has no label named \"\(name)\"."
        }
        return nil
    }

    /// A sample's row after `write`, as the Worker's next list would have it: an approval or a change request is the
    /// PR's review. Other writes leave the row as it was; a merge takes it off the open list (`PRsModel`).
    public static func applying(_ write: PRWrite, to row: PullRequestRow) -> PullRequestRow {
        let event: PRReviewEvent
        switch write {
        case let .review(sent, _, _, _), let .pendingSubmit(sent, _): event = sent
        default: return row
        }
        guard event != .comment, let status = row.status else {
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

    /// The pending review's comments; none where the detail has no pending review.
    var pendingComments: [[String: Any]] {
        (self["pendingReview"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []
    }

    /// Changes the pending review's comments, on a detail that carries the key: the first comment starts the review,
    /// and the last one's removal ends it, as on GitHub.
    mutating func changePending(_ change: ([[String: Any]]) -> [[String: Any]]) {
        guard let held = self["pendingReview"] else {
            return
        }
        var review = held as? [String: Any] ?? ["id": "sample-\(UUID().uuidString)", "body": ""]
        let comments = change(pendingComments)
        review["comments"] = comments
        self["pendingReview"] = comments.isEmpty ? NSNull() : review
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

public extension PRViewerAccess {
    /// No Worker: every request fails as `notPaired` before anything is sent. The sample PRs' client.
    static let offline = PRViewerAccess(baseURL: { nil }, bearer: { "" }, discard: {})
}
