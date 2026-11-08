import Foundation
import Observation

/// Where PRHub's events go: one vendor's SDK (`PostHogAnalytics`). Another vendor is another conformance, in one file.
@MainActor
protocol Analytics: AnyObject {
    func record(_ event: AnalyticsEvent)
    /// Settings' "Share anonymous usage". Off records nothing more and forgets the anonymous ID, so on again starts a
    /// new one.
    func setSharing(_ isOn: Bool)
}

/// The project PRHub reports to: `PRHUB_ANALYTICS_KEY` and `PRHUB_ANALYTICS_HOST` in Config/PRHub.xcconfig, through
/// Info.plist. Nil without a key, so a fork of the repo reports nowhere.
struct AnalyticsProject: Equatable, Sendable {
    var apiKey: String
    var host: URL

    init?(info: [String: Any]) {
        func setting(_ key: String) -> String? {
            let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty || value.contains("$(") ? nil : value
        }
        guard let apiKey = setting("PRHubAnalyticsKey"), let host = setting("PRHubAnalyticsHost"),
              let url = URL(string: "https://\(host)") else {
            return nil
        }
        self.apiKey = apiKey
        self.host = url
    }
}

/// What the app records through: the person's choice in Settings, kept on the phone, in front of the vendor. Nothing is
/// sent without a project, in a Debug build or under tests.
@MainActor
@Observable
final class UsageAnalytics {
    static let sharingKey = "prhub.shareUsage"

    /// On until the person turns it off in Settings.
    private(set) var isSharing: Bool
    /// The build names a project: Settings then offers the switch.
    let hasProject: Bool
    @ObservationIgnored private let sink: (any Analytics)?
    @ObservationIgnored private let defaults: UserDefaults

    init(hasProject: Bool, sink: (any Analytics)?, defaults: UserDefaults) {
        self.hasProject = hasProject
        self.sink = sink
        self.defaults = defaults
        isSharing = defaults.object(forKey: Self.sharingKey) as? Bool ?? true
    }

    /// Records nothing: the unit tests' and the samples' screenshots'.
    static func disabled() -> UsageAnalytics {
        UsageAnalytics(hasProject: false, sink: nil, defaults: .standard)
    }

    /// The vendor only for a Release build, outside the tests, with a project named.
    static func make(
        project: AnalyticsProject?, isDebugBuild: Bool, isRunningTests: Bool, defaults: UserDefaults,
        vendor: (AnalyticsProject, _ isSharing: Bool) -> any Analytics
    ) -> UsageAnalytics {
        guard let project else {
            return UsageAnalytics(hasProject: false, sink: nil, defaults: defaults)
        }
        let isSharing = defaults.object(forKey: sharingKey) as? Bool ?? true
        let sendsEvents = !isDebugBuild && !isRunningTests
        return UsageAnalytics(
            hasProject: true, sink: sendsEvents ? vendor(project, isSharing) : nil, defaults: defaults
        )
    }

    static func live() -> UsageAnalytics {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return make(
            project: AnalyticsProject(info: Bundle.main.infoDictionary ?? [:]), isDebugBuild: isDebugBuild,
            isRunningTests: AppIdentity.isRunningTests, defaults: .standard,
            vendor: { PostHogAnalytics(project: $0, isSharing: $1) }
        )
    }

    func record(_ event: AnalyticsEvent) {
        guard isSharing else {
            return
        }
        sink?.record(event)
    }

    func setSharing(_ isOn: Bool) {
        guard isOn != isSharing else {
            return
        }
        isSharing = isOn
        defaults.set(isOn, forKey: Self.sharingKey)
        sink?.setSharing(isOn)
    }
}
