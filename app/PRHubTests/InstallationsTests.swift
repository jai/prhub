import Foundation
import Testing
@testable import PRHub

/// Where the PRHub App is installed (`installations` of `GET /device/config`): Settings' GitHub access and what the
/// empty list says is missing.
@MainActor
struct InstallationsTests {
    private static let own = GitHubInstallation(
        account: "octocat", accountType: .user, installationID: 1, repositorySelection: .all
    )
    private static let acme = GitHubInstallation(
        account: "acme", accountType: .organization, installationID: 2, repositorySelection: .selected, repoCount: 2
    )
    private static let initech = GitHubInstallation(
        account: "initech", accountType: .organization, installationID: 3, repositorySelection: .all, suspended: true
    )

    private static func hosted(_ installations: [GitHubInstallation]?) -> DeviceConfig {
        DeviceConfig(
            features: [], login: "octocat", hosted: true,
            account: DeviceConfig.Account(state: .signedIn, login: "octocat"), installations: installations
        )
    }

    @Test func theWorkersHostedFixtureDecodesWithItsInstallations() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Fixture.data("device-config-hosted.json"))
        #expect(config.hosted && config.account?.login == "octocat")
        let installations = try #require(config.installations)
        #expect(installations.map(\.account) == ["octocat", "acme"])
        #expect(installations[0].accountType == .user && installations[0].repositoriesWords == "All repositories")
        #expect(installations[1].accountType == .organization && installations[1].repositoriesWords == "2 repositories")
        #expect(installations.allSatisfy { $0.avatarURL != nil && !$0.suspended })
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func anEntryThisBuildCannotReadIsLeftOutNotTheList() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"""
        {"features":{},"hosted":true,"installations":[
         {"account":"acme","account_type":"Organization","avatar_url":"https://example.com/a.png",
          "installation_id":2,"repository_selection":"all","suspended":false},
         {"account":"bigcorp","account_type":"Enterprise","installation_id":9,"repository_selection":"all",
          "suspended":false}]}
        """#.utf8))
        #expect(config.installations?.map(\.account) == ["acme"])
        let unread = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"{"features":{},"hosted":true}"#.utf8))
        #expect(unread.installations == nil)
    }

    @Test func eachInstallationOpensItsSettingsOnGitHub() {
        #expect(Self.own.settingsURL.absoluteString == "https://github.com/settings/installations/1")
        #expect(Self.acme.settingsURL.absoluteString
            == "https://github.com/organizations/acme/settings/installations/2")
        let one = GitHubInstallation(
            account: "a", accountType: .user, installationID: 4, repositorySelection: .selected, repoCount: 1
        )
        #expect(one.repositoriesWords == "1 repository")
        let unknown = GitHubInstallation(
            account: "a", accountType: .user, installationID: 5, repositorySelection: .selected
        )
        #expect(unknown.repositoriesWords == "Selected repositories")
    }

    @Test func anEmptyListSaysTheAppIsOnNoAccount() {
        let hint = PRHubPRHost.installHint(Self.hosted([]))
        #expect(hint.title == "PRHub isn't installed yet")
        #expect(hint.link == PRHubBuild.appInstallURL)
    }

    @Test func anEmptyListNamesWhereItIsInstalledAndWhatIsMissing() {
        let hint = PRHubPRHost.installHint(Self.hosted([Self.acme, Self.initech]))
        #expect(hint.message.contains("in acme, where PRHub is installed"))
        #expect(hint.message.contains("It isn't installed on your own account, octocat."))
        #expect(hint.message.contains("It's suspended on initech."))
        #expect(hint.linkTitle == "Add another account" && hint.link == PRHubBuild.appInstallURL)

        let everywhere = PRHubPRHost.installHint(Self.hosted([Self.own, Self.acme]))
        #expect(everywhere.message.contains("in octocat and acme, where PRHub is installed."))
        #expect(!everywhere.message.contains("own account") && !everywhere.message.contains("suspended"))
    }

    @Test func backFromGitHubTheEmptyListSaysItIsCheckingAndOffersNoLink() {
        let checking = PRHubPRHost.configuration(Self.hosted([]), isCheckingInstallations: true).emptyHint
        #expect(checking == PRHubPRHost.checkingHint && checking?.isChecking == true)
        let checked = PRHubPRHost.configuration(Self.hosted([Self.acme])).emptyHint
        #expect(checked?.isChecking == false && checked?.title == "No PRs yet")
        let selfHosted = DeviceConfig(features: [], login: "octocat")
        #expect(PRHubPRHost.configuration(selfHosted, isCheckingInstallations: true).emptyHint == nil)
    }

    @Test func theInstallPagesAreTheAppsInstallAndEachInstallationsSettings() {
        #expect(PRHubBuild.isInstallationPage(PRHubBuild.appInstallURL))
        #expect(PRHubBuild.isInstallationPage(Self.own.settingsURL))
        #expect(PRHubBuild.isInstallationPage(Self.acme.settingsURL))
        #expect(!PRHubBuild.isInstallationPage(URL(string: "https://github.com/acme/api/pull/7")!))
        #expect(!PRHubBuild.isInstallationPage(URL(string: "https://example.com/settings/installations/1")!))
    }

    @Test func anEmptyListWhereEveryInstallationIsSuspendedOpensItsSettings() {
        let hint = PRHubPRHost.installHint(Self.hosted([Self.initech]))
        #expect(hint.title == "PRHub is suspended")
        #expect(hint.link == Self.initech.settingsURL)
    }
}
