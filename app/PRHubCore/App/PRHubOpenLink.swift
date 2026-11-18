import Foundation
import PRKitCore

/// A PR handed to PRHub by another app. Keep the original GitHub URL as well as the page PRKit opens.
struct PRHubOpenLink: Equatable, Sendable {
    static let scheme = "prhub-pr"
    let url: URL
    let link: PRLink

    init?(_ incoming: URL) {
        guard let parts = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme, parts.host?.lowercased() == "open",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty,
              parts.fragment == nil, let query = parts.queryItems, query.count == 1,
              query[0].name == "url", let value = query[0].value,
              let url = URL(string: value),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.scheme?.lowercased() == "https", target.host?.lowercased() == "github.com",
              target.user == nil, target.password == nil, target.port == nil || target.port == 443,
              let link = PRLink(url: url), link.ref.number > 0,
              PRLinkParser.ref(in: "\(link.ref.repo)#\(link.ref.number)") == link.ref
        else {
            return nil
        }
        self.url = url
        self.link = link
    }

    /// Characters a query value keeps as they are: the URL's own `&`, `=`, `?` and `#` are encoded, so it stays one item.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The `prhub-pr://open` handoff for a GitHub PR URL, as the share extension sends it. Nil when PRHub would not
    /// open it: the same rules as an incoming handoff.
    static func handoff(for target: URL) -> URL? {
        guard let value = target.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "prhub-pr://open?url=\(value)"), PRHubOpenLink(url) != nil
        else {
            return nil
        }
        return url
    }
}
