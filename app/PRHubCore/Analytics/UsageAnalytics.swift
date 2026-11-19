import Foundation
import Observation
import PRKitCore

/// Where PRHub's events go: one vendor's SDK (`PostHogAnalytics`). Another vendor is another conformance, in one file.
@MainActor
public protocol Analytics: AnyObject {
    func record(_ event: AnalyticsEvent)
    /// Settings' "Share anonymous usage". Off records nothing more and forgets the anonymous ID, so on again starts a
    /// new one.
    func setSharing(_ isOn: Bool)
}

/// The project PRHub reports to: `PRHUB_ANALYTICS_KEY` and `PRHUB_ANALYTICS_HOST` in Config/PRHub.xcconfig, through
/// Info.plist. Nil without a key, so a fork of the repo reports nowhere.
public struct AnalyticsProject: Equatable, Sendable {
    public internal(set) var apiKey: String
    public internal(set) var host: URL

    public init?(info: [String: Any]) {
        func setting(_ key: String) -> String? {
            let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty || value.contains("$(") ? nil : value
        }
        guard let apiKey = setting("PRHubAnalyticsKey"), let host = setting("PRHubAnalyticsHost"),
              let url = URL(string: "https://\(host)")
        else {
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
public final class UsageAnalytics {
    static let sharingKey = "prhub.shareUsage"

    /// On until the person turns it off in Settings.
    public private(set) var isSharing: Bool
    /// The build names a project: Settings then offers the switch.
    public let hasProject: Bool
    @ObservationIgnored private let sink: (any Analytics)?
    @ObservationIgnored private let defaults: any PRKeyValueStore

    init(hasProject: Bool, sink: (any Analytics)?, defaults: any PRKeyValueStore) {
        self.hasProject = hasProject
        self.sink = sink
        self.defaults = defaults
        isSharing = defaults.object(forKey: Self.sharingKey) as? Bool ?? true
    }

    /// The vendor only for a Release build, outside the tests, with a project named.
    public static func make(
        project: AnalyticsProject?, isDebugBuild: Bool, isRunningTests: Bool, defaults: any PRKeyValueStore,
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

    public func record(_ event: AnalyticsEvent) {
        guard isSharing, isDue(event) else {
            return
        }
        sink?.record(event)
    }

    /// A repeating failure (`AnalyticsEvent.limitKey`) once a minute at most, as `PRFailureReporter` sends a request's.
    static let failureWindow: TimeInterval = 60
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored private var lastFailure: [String: Date] = [:]

    private func isDue(_ event: AnalyticsEvent) -> Bool {
        guard let key = event.limitKey else {
            return true
        }
        let time = now()
        if let last = lastFailure[key], time.timeIntervalSince(last) < Self.failureWindow {
            return false
        }
        lastFailure[key] = time
        return true
    }

    public func setSharing(_ isOn: Bool) {
        guard isOn != isSharing else {
            return
        }
        isSharing = isOn
        defaults.set(isOn, forKey: Self.sharingKey)
        sink?.setSharing(isOn)
    }
}
