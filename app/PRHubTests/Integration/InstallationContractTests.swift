import Foundation
import PRContractFixtures
@testable import PRHubCore
import Testing

@MainActor
struct InstallationContractTests {
    @Test func theWorkersHostedFixtureDecodesWithItsInstallations() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: ContractFixtures.data("device-config-hosted.json"))
        #expect(config.hosted && config.account?.login == "octocat")
        let installations = try #require(config.installations)
        #expect(installations.map(\.account) == ["octocat", "acme"])
        #expect(installations[0].accountType == .user && installations[0].repositoriesWords == "All repositories")
        #expect(installations[1].accountType == .organization && installations[1].repositoriesWords == "2 repositories")
        #expect(installations.allSatisfy { $0.avatarURL != nil && !$0.suspended })
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
    }
}
