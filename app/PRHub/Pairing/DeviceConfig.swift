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

    init(
        features: Set<DeviceFeature>, ownerName: String? = nil, appVersionMin: String? = nil, push: String? = nil,
        login: String? = nil, orgs: [String]? = nil
    ) {
        self.features = features
        self.ownerName = ownerName
        self.appVersionMin = appVersionMin
        self.push = push
        self.login = login
        self.orgs = orgs
    }

    private enum CodingKeys: String, CodingKey {
        case features
        case ownerName = "owner_name"
        case appVersionMin = "app_version_min"
        case push
        case login
        case orgs
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
    }

    func isOn(_ feature: DeviceFeature) -> Bool {
        features.contains(feature)
    }
}
