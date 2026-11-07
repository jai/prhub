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

    /// The stored detail with `write` applied as GitHub would show it: a review or a comment joins the conversation,
    /// signed by `login`. Other writes leave it as it was.
    public static func applying(_ write: PRWrite, to detail: Data, login: String, now: Date = .now) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: detail)) as? [String: Any] else {
            return detail
        }
        let author: [String: Any] = ["login": login, "avatarUrl": NSNull()]
        let id = "sample-\(UUID().uuidString)"
        let stamp = now.ISO8601Format()
        let (key, item): (String, [String: Any])
        switch write {
        case let .review(event, body, _, _):
            (key, item) = ("reviews", [
                "id": id, "author": author, "state": event.state, "body": body, "submittedAt": stamp,
            ])
        case let .comment(body):
            (key, item) = ("comments", ["id": id, "author": author, "body": body, "createdAt": stamp])
        default:
            return detail
        }
        var holder = object[key] as? [String: Any] ?? [:]
        holder["nodes"] = (holder["nodes"] as? [Any] ?? []) + [item]
        object[key] = holder
        return (try? JSONSerialization.data(withJSONObject: object)) ?? detail
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
