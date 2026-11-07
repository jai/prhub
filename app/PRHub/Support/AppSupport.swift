import Foundation
#if os(iOS)
import UIKit
#endif

/// The app's bundle ID: the keychain service its device secret and Worker URL live under. Installs from earlier PRHub
/// builds keep theirs under the same names, so they stay paired across updates.
enum AppIdentity {
    static let bundleID: String = Bundle.main.bundleIdentifier ?? "com.jaigovindani.prreview"

    /// The XCTest host: the unit tests get an empty window instead of the live UI.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `<CFBundleShortVersionString> (<CFBundleVersion>)`.
    static func appVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// Whether the device secret's "not found" may be believed: a keychain that cannot decrypt yet (a wake before the
    /// first unlock) has been seen to answer not-found (`DeviceSecretStore.loadOrCreate`).
    @MainActor static func protectedDataAvailability() -> @Sendable () -> Bool {
        #if os(iOS)
        let application = UIApplication.shared
        return { application.isProtectedDataAvailable }
        #else
        return { true }
        #endif
    }
}

/// Whether someone is looking at the app: a request then waits for a network.
@MainActor
func appIsInForeground() -> Bool {
    #if os(iOS)
    UIApplication.shared.applicationState != .background
    #else
    true
    #endif
}
