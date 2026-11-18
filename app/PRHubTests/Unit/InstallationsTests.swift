import Foundation
@testable import PRHubCore
import Testing

/// Where the PRHub App is installed (`installations` of `GET /device/config`): Settings' GitHub access and what the
/// empty list says is missing.
@MainActor
struct InstallationsTests {
    private static let locale = Locale(identifier: "en_US")
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
        let hint = PRHubPRHost.installHint(Self.hosted([]), locale: Self.locale)
        #expect(hint.title == "PRHub isn't installed yet")
        #expect(hint.link == PRHubBuild.appInstallURL)
    }

    @Test func anEmptyListNamesWhereItIsInstalledAndWhatIsMissing() {
        let hint = PRHubPRHost.installHint(Self.hosted([Self.acme, Self.initech]), locale: Self.locale)
        #expect(hint.message.contains("in acme, where PRHub is installed"))
        #expect(hint.message.contains("It isn't installed on your own account, octocat."))
        #expect(hint.message.contains("It's suspended on initech."))
        #expect(hint.linkTitle == "Add another account" && hint.link == PRHubBuild.appInstallURL)

        let everywhere = PRHubPRHost.installHint(Self.hosted([Self.own, Self.acme]), locale: Self.locale)
        #expect(everywhere.message.contains("in octocat and acme, where PRHub is installed."))
        #expect(!everywhere.message.contains("own account") && !everywhere.message.contains("suspended"))
    }

    @Test func backFromGitHubTheEmptyListSaysItIsCheckingAndOffersNoLink() {
        let checking = PRHubPRHost.configuration(Self.hosted([]), isCheckingInstallations: true, locale: Self.locale).emptyHint
        #expect(checking == PRHubPRHost.checkingHint && checking?.isChecking == true)
        let checked = PRHubPRHost.configuration(Self.hosted([Self.acme]), locale: Self.locale).emptyHint
        #expect(checked?.isChecking == false && checked?.title == "No PRs yet")
        let selfHosted = DeviceConfig(features: [], login: "octocat")
        #expect(PRHubPRHost.configuration(selfHosted, isCheckingInstallations: true, locale: Self.locale).emptyHint == nil)
    }

    @Test func theInstallPagesAreTheAppsInstallAndEachInstallationsSettings() throws {
        #expect(PRHubBuild.isInstallationPage(PRHubBuild.appInstallURL))
        #expect(PRHubBuild.isInstallationPage(Self.own.settingsURL))
        #expect(PRHubBuild.isInstallationPage(Self.acme.settingsURL))
        #expect(try !PRHubBuild.isInstallationPage(#require(URL(string: "https://github.com/acme/api/pull/7"))))
        #expect(try !PRHubBuild.isInstallationPage(#require(URL(string: "https://example.com/settings/installations/1"))))
    }

    @Test func anEmptyListWhereEveryInstallationIsSuspendedOpensItsSettings() {
        let hint = PRHubPRHost.installHint(Self.hosted([Self.initech]), locale: Self.locale)
        #expect(hint.title == "PRHub is suspended")
        #expect(hint.link == Self.initech.settingsURL)
    }

    @Test func theHostedListPointsAtTheAppsInstallPage() {
        let hosted = PRHubPRHost.configuration(DeviceConfig(features: [], hosted: true), locale: Self.locale)
        #expect(hosted.emptyHint == PRHubPRHost.genericInstallHint)
        #expect(hosted.emptyHint?.link == PRHubBuild.appInstallURL)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: []), locale: Self.locale).emptyHint == nil)
    }

    /// Signed in with no Anthropic key, the Key lines page says to add one, and opens Settings to do it.
    @Test func theHostedWorkerWithNoKeyPointsKeyLinesAtSettings() {
        let noKey = PRHubPRHost.configuration(DeviceConfig(features: [.push], hosted: true), locale: Self.locale)
        #expect(!noKey.isOn(.keyLines))
        #expect(noKey.keyLinesHint == PRHubPRHost.anthropicKeyHint)
        #expect(noKey.keyLinesHint?.link == PRHubBuild.settingsURL)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [.keyLines], hosted: true), locale: Self.locale).keyLinesHint == nil)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [.push]), locale: Self.locale).keyLinesHint == nil)
    }
}
