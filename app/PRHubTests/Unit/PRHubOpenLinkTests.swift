import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

struct PRHubOpenLinkTests {
    private static func incoming(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try #require(parts.url)
    }

    @Test(arguments: ["", "/files", "/changes"])
    func theOriginalGitHubURLAndItsPageAreKept(_ suffix: String) throws {
        let target = "https://github.com/acme/web/pull/412\(suffix)?w=1#diff-abcR12"
        let destination = try #require(try PRHubOpenLink(Self.incoming(target)))
        #expect(destination.url.absoluteString == target)
        #expect(destination.link == PRLink(ref: PullRequestRef(repo: "acme/web", number: 412),
                                           showsDiff: !suffix.isEmpty))
    }

    @Test(arguments: [
        "http://github.com/acme/web/pull/412",
        "https://github.com.evil.example/acme/web/pull/412",
        "https://github.com@evil.example/acme/web/pull/412",
        "https://name:password@github.com/acme/web/pull/412",
        "https://github.com/acme/web/issues/412",
        "https://github.com/acme/web/pull/0",
        "https://github.com/acme/web/pull/-1",
        "https://github.com/acme%2Fother/web/pull/412",
        "https://github.com:8443/acme/web/pull/412",
        "javascript:alert(1)",
    ])
    func onlyAGitHubHTTPSPullRequestIsAccepted(_ target: String) throws {
        #expect(try PRHubOpenLink(Self.incoming(target)) == nil)
    }

    @Test(arguments: [
        "prhub-pr://open",
        "prhub-pr://open?url=",
        "prhub-pr://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412&url=other",
        "prhub-pr://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412&extra=1",
        "prhub-pr://open/path?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412",
        "prhub-pr://user@open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412",
        "prhub-pr://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412#fragment",
        "prhub-pr://setup?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412",
        "prhub://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412",
        "https://open?url=https%3A%2F%2Fgithub.com%2Facme%2Fweb%2Fpull%2F412",
    ])
    func aMalformedOrAmbiguousHandoffIsRejected(_ text: String) throws {
        #expect(try PRHubOpenLink(#require(URL(string: text))) == nil)
    }

    @Test(arguments: [
        "https://github.com/acme/web/pull/412",
        "https://github.com/acme/web/pull/412/files?w=1&diff=split#diff-abcR12",
    ])
    func aSharedPullRequestLinkBecomesTheHandoffForTheSameURL(_ target: String) throws {
        let shared = try #require(URL(string: target))
        let handoff = try #require(PRHubOpenLink.handoff(for: shared))
        #expect(handoff.scheme == "prhub-pr")
        #expect(try #require(PRHubOpenLink(handoff)).url.absoluteString == target)
    }

    @Test(arguments: [
        "https://github.com/acme/web/issues/412",
        "https://example.com/acme/web/pull/412",
        "http://github.com/acme/web/pull/412",
    ])
    func aSharedLinkThatIsNotAPullRequestHasNoHandoff(_ target: String) throws {
        let shared = try #require(URL(string: target))
        #expect(PRHubOpenLink.handoff(for: shared) == nil)
    }
}
