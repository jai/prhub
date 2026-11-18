import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

struct OpenLinkEnvironmentTests {
    private static func incoming(_ target: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: target)]
        return try #require(parts.url)
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

    @MainActor @Test func eachHandoffIsRecordedAndOtherLinksAreNot() throws {
        let sink = AnalyticsTests.RecordingAnalytics()
        let environment = PRHubEnvironment.sample(usage: AnalyticsTests.usage(sink))
        try environment.openPullRequestLink(Self.incoming("https://github.com/acme/web/pull/412"))
        try environment.openPullRequestLink(Self.incoming("https://github.com/acme/web/issues/412"))
        environment.openPullRequestLink(PRHubBuild.settingsURL)
        #expect(sink.events == [.pullRequestLinkOpened(.opened), .pullRequestLinkOpened(.notAPullRequest)])
    }

    @MainActor @Test func aRefusedHandoffChangesNeitherTheTabNorItsOpenPR() throws {
        let environment = PRHubEnvironment.sample()
        environment.navigation.selectedTab = .settings
        #expect(try !environment.openPullRequestLink(Self.incoming("https://github.com/acme/web/issues/412")))
        #expect(environment.navigation.selectedTab == .settings)
        #expect(environment.prs.navigation.pending == nil)
    }
}
