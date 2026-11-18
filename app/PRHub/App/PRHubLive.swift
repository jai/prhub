import Foundation
import PRHubCore

extension PRHubEnvironment {
    static let shared = live(usage: .live(), testFlightGroup: .current)
}

extension UsageAnalytics {
    static func live(defaults: UserDefaults = .standard) -> UsageAnalytics {
        #if DEBUG
            let isDebugBuild = true
        #else
            let isDebugBuild = false
        #endif
        return make(
            project: AnalyticsProject(info: Bundle.main.infoDictionary ?? [:]), isDebugBuild: isDebugBuild,
            isRunningTests: AppIdentity.isRunningTests, defaults: defaults,
            vendor: { PostHogAnalytics(project: $0, isSharing: $1) }
        )
    }
}

extension TestFlightGroup {
    static var current: TestFlightGroup {
        #if PRHUB_INTERNAL_TESTFLIGHT
            .internal
        #else
            .public
        #endif
    }
}
