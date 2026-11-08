import Foundation

/// One installation of a GitHub App on a person's account or an org they belong to: an entry of the hosted Worker's
/// `installations` (`GET /device/config`, docs/api.md). Which repos the App reaches there, and where its settings are.
public struct GitHubInstallation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum AccountType: String, Codable, Sendable {
        case user = "User"
        case organization = "Organization"
    }

    public enum RepositorySelection: String, Codable, Sendable {
        case all
        case selected
    }

    /// The user or org's login.
    public var account: String
    public var accountType: AccountType
    public var avatarURL: URL?
    public var installationID: Int
    public var repositorySelection: RepositorySelection
    /// With `selected`: how many of the picked repos the person sees. Unknown while suspended.
    public var repoCount: Int?
    public var suspended: Bool

    public var id: Int { installationID }

    public init(
        account: String, accountType: AccountType, avatarURL: URL? = nil, installationID: Int,
        repositorySelection: RepositorySelection, repoCount: Int? = nil, suspended: Bool = false
    ) {
        self.account = account
        self.accountType = accountType
        self.avatarURL = avatarURL
        self.installationID = installationID
        self.repositorySelection = repositorySelection
        self.repoCount = repoCount
        self.suspended = suspended
    }

    /// GitHub's page for this installation, where its repos are picked, and where it is suspended or uninstalled.
    public var settingsURL: URL {
        let path = switch accountType {
        case .user: "settings/installations/\(installationID)"
        case .organization: "organizations/\(account)/settings/installations/\(installationID)"
        }
        return URL(string: "https://github.com/\(path)") ?? URL(string: "https://github.com/settings/installations")!
    }

    /// "All repositories", "3 repositories", or "Selected repositories" when the count is unknown.
    public var repositoriesWords: String {
        switch (repositorySelection, repoCount) {
        case (.all, _): "All repositories"
        case (.selected, 1): "1 repository"
        case let (.selected, count?): "\(count) repositories"
        case (.selected, nil): "Selected repositories"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case account
        case accountType = "account_type"
        case avatarURL = "avatar_url"
        case installationID = "installation_id"
        case repositorySelection = "repository_selection"
        case repoCount = "repo_count"
        case suspended
    }
}
