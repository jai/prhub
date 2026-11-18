#if os(iOS)
    import PRHubCore
    import UIKit
    import UserNotifications

    /// Launch wiring that must not wait for a view. The silent wake needs no permission; review alerts ask for it after
    /// pairing (`PRHubAlertPermission`), and a tap on one opens its PR (`PRHubNotificationDelegate`), so the delegate is set
    /// before launch returns, as a tap that launches the app needs.
    @MainActor
    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            guard !Self.isFixtureLaunch, !AppIdentity.isRunningTests else {
                return true
            }
            UNUserNotificationCenter.current().delegate = PRHubEnvironment.shared.notificationDelegate
            application.registerForRemoteNotifications()
            return true
        }

        /// To the pr-worker's `POST /device/register`, when that Worker pushes (docs/api.md).
        func application(
            _: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            PRHubEnvironment.shared.prs.register(apnsToken: APNSEnvironment.hex(deviceToken))
        }

        /// No token: PRHub syncs when opened instead.
        func application(
            _: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError _: any Error
        ) {}

        /// PRHub's only background push is the pr-worker's silent wake; its alerts are taps. The
        /// completion-handler variant on purpose: UIKit's handler asserts the main thread.
        func application(
            _: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any],
            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
        ) {
            guard !Self.isFixtureLaunch else {
                completionHandler(.noData)
                return
            }
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
                // Beside the sync: the alerts in Notification Center, so a tap later never waits on the network.
                async let alerts: Void = PRHubEnvironment.shared.keepAlerts()
                let outcome = await PRHubEnvironment.shared.prs.refresh(.silentPush)
                await alerts
                completionHandler(Self.backgroundResult(outcome))
            }
        }
    }

    extension AppDelegate {
        private static var isFixtureLaunch: Bool {
            #if DEBUG
                PRHubScreenshots.isFixtureLaunch
            #else
                false
            #endif
        }

        private static func backgroundResult(_ outcome: PRSyncOutcome) -> UIBackgroundFetchResult {
            switch outcome {
            case .changed: .newData
            case .unchanged: .noData
            case .failed: .failed
            }
        }
    }
#endif
