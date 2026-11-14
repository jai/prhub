import Foundation
import Observation

/// One build of PRHub: `CFBundleShortVersionString` and `CFBundleVersion`.
struct AppBuild: Codable, Equatable, Sendable {
    var version: String
    var build: String

    /// This app's own, from its Info.plist.
    static let running = AppBuild(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    )

    /// A later version, or the same version with a higher build number.
    func isNewer(than other: AppBuild) -> Bool {
        switch version.compare(other.version, options: .numeric) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: build.compare(other.build, options: .numeric) == .orderedDescending
        }
    }
}

/// The TestFlight group this build was made for: Xcode Cloud's Internal - TestFlight workflow builds for the Internal
/// group (`app/ci_scripts/ci_post_clone.sh` sets `PRHUB_INTERNAL_TESTFLIGHT`); every other build is a release, for the
/// Public group.
enum TestFlightGroup: String, CaseIterable, Sendable {
    case `internal`, `public`

    static var current: TestFlightGroup {
        #if PRHUB_INTERNAL_TESTFLIGHT
        .internal
        #else
        .public
        #endif
    }
}

/// Update available: when the Worker's config names a newer build for this build's TestFlight group, an alert offers
/// TestFlight. Later skips that build; a newer one offers again. Checked at launch and on each return to the front, at
/// most hourly.
@MainActor
@Observable
final class PRHubUpdate {
    /// The newer build the alert offers; nil when none is offered.
    private(set) var offered: AppBuild?

    /// PRHub on TestFlight.
    static let testFlightURL = URL(string: "itms-beta://beta.itunes.apple.com/v1/app/6831601628")!
    nonisolated static let laterKey = "updateLaterBuild"
    static let interval: TimeInterval = 60 * 60

    @ObservationIgnored private let running: AppBuild
    @ObservationIgnored private let group: TestFlightGroup
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private let usage: UsageAnalytics
    @ObservationIgnored private var checkedAt: Date?

    /// Off in a Debug build unless a UI test asks for it: a build from Xcode is never on TestFlight.
    init(
        running: AppBuild = .running, group: TestFlightGroup = .current, defaults: UserDefaults = .standard,
        isEnabled: Bool = PRHubUpdate.isReleaseBuild, usage: UsageAnalytics = .disabled(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.usage = usage
        self.running = running
        self.group = group
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
    }

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// After a config read. Nothing within the hour after the last check, or without a config to check.
    func check(_ config: DeviceConfig?) {
        guard isEnabled, offered == nil, let config else {
            return
        }
        let time = now()
        if let checkedAt, time.timeIntervalSince(checkedAt) < Self.interval {
            return
        }
        checkedAt = time
        guard let latest = config.appLatest?.build(for: group), latest.isNewer(than: running),
              defaults.string(forKey: Self.laterKey) != latest.build else {
            return
        }
        offered = latest
        usage.record(.updateOffered(group, build: Int(latest.build) ?? 0))
    }

    /// Update, as the alert opens `testFlightURL`: offered again at the next check if still not installed.
    func update() {
        offered = nil
        usage.record(.updateAnswered(.update))
    }

    /// Later: not this build again.
    func later() {
        guard let offered else {
            return
        }
        defaults.set(offered.build, forKey: Self.laterKey)
        self.offered = nil
        usage.record(.updateAnswered(.later))
    }
}
