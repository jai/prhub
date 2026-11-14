import Foundation
import PRKit

/// A PR handed to PRHub by another app. Keep the original GitHub URL as well as the page PRKit opens.
struct PRHubOpenLink: Equatable, Sendable {
    let url: URL
    let link: PRLink

    init?(_ incoming: URL) {
        guard let parts = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "prhub-pr", parts.host?.lowercased() == "open",
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
}

extension PRHubEnvironment {
    /// The sample environment owns its own navigation and PR sessions; a PR link never ends the samples.
    @discardableResult
    func openPullRequestLink(_ url: URL) -> Bool {
        guard let destination = PRHubOpenLink(url) else {
            return false
        }
        let active = sample ?? self
        active.prs.open(destination.link)
        active.navigation.selectedTab = .prs
        return true
    }
}
