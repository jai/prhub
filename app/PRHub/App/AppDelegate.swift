import UIKit
import UserNotifications

/// Launch wiring that must not wait for a view. The silent wake needs no permission; review alerts ask for it after
/// pairing (`PRHubAlertPermission`), and a tap on one opens its PR (`PRHubNotificationDelegate`), so the delegate is set
/// before launch returns, as a tap that launches the app needs.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !AppIdentity.isRunningTests else {
            return true
        }
        UNUserNotificationCenter.current().delegate = PRHubEnvironment.shared.notificationDelegate
        application.registerForRemoteNotifications()
        return true
    }

    /// To the pr-worker's `POST /device/register`, when that Worker pushes (docs/api.md).
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PRHubEnvironment.shared.prs.register(apnsToken: APNSEnvironment.hex(deviceToken))
    }

    /// No token: PRHub syncs when opened instead.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {}

    /// PRHub's only background push is the pr-worker's silent wake, through the relay; its alerts are taps. The
    /// completion-handler variant on purpose: UIKit's handler asserts the main thread.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if PRHubNotificationDelegate.isSignedOut(userInfo) {
            Task {
                await PRHubEnvironment.shared.signedOutByGitHub()
                completionHandler(.newData)
            }
            return
        }
        guard PRPush(userInfo: userInfo) == .sync else {
            completionHandler(.noData)
            return
        }
        Task {
            completionHandler(Self.backgroundResult(await PRHubEnvironment.shared.prs.refresh(.silentPush)))
        }
    }
}

extension AppDelegate {
    private static func backgroundResult(_ outcome: PRSyncOutcome) -> UIBackgroundFetchResult {
        switch outcome {
        case .changed: .newData
        case .unchanged: .noData
        case .failed: .failed
        }
    }
}
