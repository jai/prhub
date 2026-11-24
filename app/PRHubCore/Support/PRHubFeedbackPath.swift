import FeatureKit
import Foundation

/// Where Feedback goes, and whose list it keeps between launches. Feedback follows it (`followFeedbackPath`): another
/// FeedbackKit root, or another account, is another model, with its own kept list and its own tokens.
public struct PRHubFeedbackPath: Equatable, Sendable {
    /// FeedbackKit's root on the direct path; nil through the Worker's `/feedback` routes.
    var root: URL?
    /// The account's name for its kept list (`FeedbackKeep.standard(named:)`). Nil before a config names the person:
    /// nothing is kept.
    var account: String?

    init(root: URL? = nil, account: String? = nil) {
        self.root = root
        self.account = account
    }

    /// The Worker's host with the person on it: the hosted Worker's user id, else the login a pr-worker acts as.
    init(host: String?, config: DeviceConfig?) {
        root = config?.feedbackDirect?.url
        account = Self.accountName(host: host, person: config?.account?.userId ?? config?.account?.login ?? config?.login)
    }

    /// One folder name: lowercase letters, digits, dots and dashes; anything else is an underscore.
    static func accountName(host: String?, person: String?) -> String? {
        guard let host, !host.isEmpty, let person, !person.isEmpty else {
            return nil
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let name = "\(host)-\(person)".lowercased().map { allowed.contains($0) ? $0 : "_" }
        return String(name.prefix(120))
    }

    /// The account's kept list; nil keeps nothing.
    var keep: FeedbackKeep? {
        account.flatMap { FeedbackKeep.standard(named: $0) }
    }
}
