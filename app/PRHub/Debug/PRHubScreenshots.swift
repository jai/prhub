#if DEBUG
    import Foundation
    import PRHubCore
    import SwiftUI

    /// Debug launch scenarios are built in PRHubCore; appearance stays with the app's views.
    enum PRHubScreenshots {
        static let appearanceKey = "PRHubAppearance"

        static func colorScheme(_ defaults: UserDefaults = .standard) -> ColorScheme? {
            switch defaults.string(forKey: appearanceKey) {
            case "dark": .dark
            case "light": .light
            default: nil
            }
        }

        @MainActor static func environment() -> PRHubEnvironment? {
            PRHubScreenshotEnvironment.environment(usage: { UsageAnalytics.live(defaults: $0) }, testFlightGroup: .current)
        }

        static var isFixtureLaunch: Bool {
            PRHubUITestResources.isFixtureLaunch
        }

        static var forcesCompactWidth: Bool {
            ProcessInfo.processInfo.arguments.contains("-PRHubCompactWidth")
        }
    }
#endif
