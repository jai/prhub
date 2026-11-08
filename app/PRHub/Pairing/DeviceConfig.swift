import Foundation

/// The features a pr-worker says it serves (`features` of `GET /device/config`, docs/api.md).
enum DeviceFeature: String, CaseIterable, Sendable {
    case askAI = "ask_ai"
    case keyLines = "key_lines"
    case rewrite
    case feedback
    case push
    case webhooks

    var title: String {
        switch self {
        case .askAI: "Ask AI"
        case .keyLines: "Key lines"
        case .rewrite: "Rewrite"
        case .feedback: "Feedback"
        case .push: "Push"
        case .webhooks: "Webhooks"
        }
    }
}

/// `GET /device/config`. A feature key the Worker does not send is off, a key this build does not know is ignored, and a
/// value that is not a boolean is off.
struct DeviceConfig: Codable, Equatable, Sendable {
    var features: Set<DeviceFeature>
    var ownerName: String?
    var appVersionMin: String?
    var push: String?
    /// A pr-worker's: the GitHub login it acts as, `nil` when GitHub could not be asked.
    var login: String?
    /// A pr-worker's `GITHUB_ORGS`: the PR filter's default selection. `nil` when unset.
    var orgs: [String]?
    /// The hosted Worker's (docs/api.md, "Hosted sign-in"): Settings then shows the account, not the Worker.
    var hosted: Bool
    /// The hosted Worker's person; nil on a self-hosted one.
    var account: Account?
    /// The hosted Worker's: where the PRHub App is installed for the person. Nil before the Worker first read them, and
    /// on a self-hosted Worker.
    var installations: [GitHubInstallation]?

    /// `account` of `GET /device/config` on the hosted Worker.
    struct Account: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case signedIn = "signed_in"
            case signedOut = "signed_out"
        }

        var state: State
        var login: String?
        var userId: String?
        /// Whether the person gave their own Anthropic key. The key itself is never answered.
        var anthropicKey: Bool
        /// A signed-out account's why: `revoked`, `refresh_expired` or `signed_out`.
        var reason: String?

        init(
            state: State, login: String? = nil, userId: String? = nil, anthropicKey: Bool = false,
            reason: String? = nil
        ) {
            self.state = state
            self.login = login
            self.userId = userId
            self.anthropicKey = anthropicKey
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case state, login, reason
            case userId = "user_id"
            case anthropicKey = "anthropic_key"
        }

        /// A state this build does not know reads as signed out: the app then offers Sign in again.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = (try? container.decode(State.self, forKey: .state)) ?? .signedOut
            login = try? container.decodeIfPresent(String.self, forKey: .login)
            userId = try? container.decodeIfPresent(String.self, forKey: .userId)
            anthropicKey = (try? container.decodeIfPresent(Bool.self, forKey: .anthropicKey)) == true
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    init(
        features: Set<DeviceFeature>, ownerName: String? = nil, appVersionMin: String? = nil, push: String? = nil,
        login: String? = nil, orgs: [String]? = nil, hosted: Bool = false, account: Account? = nil,
        installations: [GitHubInstallation]? = nil
    ) {
        self.features = features
        self.ownerName = ownerName
        self.appVersionMin = appVersionMin
        self.push = push
        self.login = login
        self.orgs = orgs
        self.hosted = hosted
        self.account = account
        self.installations = installations
    }

    private enum CodingKeys: String, CodingKey {
        case features
        case ownerName = "owner_name"
        case appVersionMin = "app_version_min"
        case push
        case login
        case orgs
        case hosted
        case account
        case installations
    }

    /// One entry of `installations`: one this build cannot read is left out, not the whole list.
    private struct LossyInstallation: Decodable {
        let value: GitHubInstallation?

        init(from decoder: any Decoder) throws {
            value = try? GitHubInstallation(from: decoder)
        }
    }

    private struct FeatureKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var features: Set<DeviceFeature> = []
        if let flags = try? container.nestedContainer(keyedBy: FeatureKey.self, forKey: .features) {
            for key in flags.allKeys {
                guard let feature = DeviceFeature(rawValue: key.stringValue) else {
                    continue
                }
                if (try? flags.decode(Bool.self, forKey: key)) == true {
                    features.insert(feature)
                }
            }
        }
        self.features = features
        ownerName = try? container.decodeIfPresent(String.self, forKey: .ownerName)
        appVersionMin = try? container.decodeIfPresent(String.self, forKey: .appVersionMin)
        push = try? container.decodeIfPresent(String.self, forKey: .push)
        login = try? container.decodeIfPresent(String.self, forKey: .login)
        orgs = try? container.decodeIfPresent([String].self, forKey: .orgs)
        hosted = (try? container.decodeIfPresent(Bool.self, forKey: .hosted)) == true
        account = try? container.decodeIfPresent(Account.self, forKey: .account)
        installations = (try? container.decodeIfPresent([LossyInstallation].self, forKey: .installations))?
            .compactMap(\.value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var flags = container.nestedContainer(keyedBy: FeatureKey.self, forKey: .features)
        for feature in DeviceFeature.allCases {
            try flags.encode(features.contains(feature), forKey: FeatureKey(stringValue: feature.rawValue))
        }
        try container.encodeIfPresent(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(appVersionMin, forKey: .appVersionMin)
        try container.encodeIfPresent(push, forKey: .push)
        try container.encodeIfPresent(login, forKey: .login)
        try container.encodeIfPresent(orgs, forKey: .orgs)
        if hosted {
            try container.encode(hosted, forKey: .hosted)
        }
        try container.encodeIfPresent(account, forKey: .account)
        try container.encodeIfPresent(installations, forKey: .installations)
    }

    func isOn(_ feature: DeviceFeature) -> Bool {
        features.contains(feature)
    }
}
