import Foundation
import Testing
@testable import PRHub
@testable import PRKit

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
        let destination = try #require(PRHubOpenLink(try Self.incoming(target)))
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
        #expect(PRHubOpenLink(try Self.incoming(target)) == nil)
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
        #expect(PRHubOpenLink(try #require(URL(string: text))) == nil)
    }

    @MainActor @Test func aHandoffSelectsThePRsTabAndOpensItsDiff() throws {
        let environment = PRHubEnvironment.sample()
        environment.navigation.selectedTab = .settings
        let url = try Self.incoming("https://github.com/acme/web/pull/412/files")
        #expect(environment.openPullRequestLink(url))
        #expect(environment.navigation.selectedTab == .prs)
        #expect(environment.prs.navigation.pending?.link == PRLink(
            ref: PullRequestRef(repo: "acme/web", number: 412), showsDiff: true
        ))
    }

    @MainActor @Test func aHandoffUsesTheCurrentSamplesWithoutEndingThem() throws {
        let environment = PRHubEnvironment(connection: PRHubEnvironment.sample().connection)
        environment.navigation.selectedTab = .settings
        environment.startSample()
        let sample = try #require(environment.sample)
        sample.navigation.selectedTab = .settings
        let url = try Self.incoming("https://github.com/acme/web/pull/412")

        #expect(environment.openPullRequestLink(url))
        #expect(environment.sample === sample)
        #expect(sample.navigation.selectedTab == .prs)
        #expect(sample.prs.navigation.pending?.link.ref == PullRequestRef(repo: "acme/web", number: 412))
        #expect(environment.navigation.selectedTab == .settings)
        #expect(environment.prs.navigation.pending == nil)
    }

    @MainActor @Test func aRefusedHandoffChangesNeitherTheTabNorItsOpenPR() throws {
        let environment = PRHubEnvironment.sample()
        environment.navigation.selectedTab = .settings
        #expect(!environment.openPullRequestLink(try Self.incoming("https://github.com/acme/web/issues/412")))
        #expect(environment.navigation.selectedTab == .settings)
        #expect(environment.prs.navigation.pending == nil)
    }
}
