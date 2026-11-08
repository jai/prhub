import Foundation

/// A push from the pr-worker, read once where it arrives (docs/api.md, "Alerts"): the silent wake that
/// syncs the list, or an alert about one PR that opens it on a tap. Anything else is not a PR push, and `init` is nil.
public enum PRPush: Equatable, Sendable {
    /// `reason: pr_sync`, the silent wake.
    case sync
    /// `reason: pr_alert`: a visible push about one PR.
    case alert(kind: AlertKind, pullRequest: PullRequestRef)

    /// What an alert says happened. For wording only: a kind this build does not know still opens its PR.
    public enum AlertKind: Equatable, Sendable {
        case reviewRequested, approved, changesRequested
        case unknown(String)

        init(_ word: String) {
            switch word {
            case "review_requested": self = .reviewRequested
            case "approved": self = .approved
            case "changes_requested": self = .changesRequested
            default: self = .unknown(word)
            }
        }
    }

    /// A notification's `userInfo`, or a payload decoded from JSON. An alert whose PR is not `owner/repo` and a
    /// number above zero is nil: it would open nothing.
    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["reason"] as? String {
        case "pr_sync":
            self = .sync
        case "pr_alert":
            guard let named = userInfo["pr"] as? [String: Any], let repo = named["repo"] as? String,
                  let number = (named["number"] as? NSNumber)?.intValue,
                  let ref = PRLinkParser.ref(in: "\(repo)#\(number)") else {
                return nil
            }
            self = .alert(kind: AlertKind(userInfo["kind"] as? String ?? ""), pullRequest: ref)
        default:
            return nil
        }
    }

    /// The PR's row as `GET /prs` lists it, which an alert carries (docs/api.md, "Alerts"), so the phone can fetch its
    /// stored detail and diff before the tap: nil when the push has none or it is not a row.
    public static func row(in userInfo: [AnyHashable: Any]) -> PullRequestRow? {
        guard let row = userInfo["row"], JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row) else {
            return nil
        }
        return try? JSONDecoder().decode(PullRequestRow.self, from: data)
    }

    /// The PR an alert opens; nil for the wake.
    public var openedPullRequest: PullRequestRef? {
        if case let .alert(_, pullRequest) = self {
            return pullRequest
        }
        return nil
    }
}
