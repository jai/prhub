import Foundation
import PRKitCore
import UserNotifications

/// The app's Keychain items are under its own bundle ID, which this extension's is not.
enum AppIdentity {
    static let bundleID = "com.jaigovindani.prreview"
}

/// PRHub's Notification Service Extension (docs/api.md, "Alerts"): an alert that carries its PR's row has the PR's
/// stored detail and diff fetched into the app group's mirror before it shows, so a tap opens the PR from the phone.
/// The alert itself is never changed, and it shows whatever happens: no row, no Worker, a slow network, an error.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// Well inside iOS's 30 s for an extension: a slow network delays the banner by this much at most.
    static let deadline = Duration.seconds(6)

    private var delivered: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?
    private let lock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.lock()
        delivered = contentHandler
        content = request.content
        lock.unlock()
        let userInfo = request.content.userInfo
        guard PRPush(userInfo: userInfo)?.openedPullRequest != nil else {
            deliver()
            return
        }
        let row = PRPush.row(in: userInfo)
        let group = Bundle.main.object(forInfoDictionaryKey: "PRHubAppGroup") as? String
        let directory = PRMirrorLocation.directory(appGroup: group)
        let endpoint = WorkerEndpoint(store: WorkerURLStore(service: AppIdentity.bundleID, account: "worker-url"))
        let secrets = DeviceSecretStore(
            service: AppIdentity.bundleID, account: "device-secret", isProtectedDataAvailable: { false }
        )
        let access = PRViewerAccess(
            baseURL: { endpoint.url },
            // Read, never made: a secret made here would unpair the phone.
            bearer: {
                guard let secret = try secrets.load() else {
                    throw PRViewerError.notPaired
                }
                return secret
            },
            discard: {}
        )
        let prefetch = PRPushPrefetch(client: PRViewerClient(access: access, isInForeground: { false }), directory: directory)
        Task {
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await prefetch.prefetch(row, deadline: Self.deadline)
            let elapsed = clock.now - started
            let milliseconds = Int(elapsed.components.seconds) * 1000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            PRPushPrefetchLog(directory: directory).append(.init(outcome: outcome, milliseconds: milliseconds))
            self.deliver()
        }
    }

    /// iOS is about to give up on the extension: the alert shows as it came.
    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    /// Once: the first of the prefetch's end and iOS's deadline.
    private func deliver() {
        lock.lock()
        let handler = delivered
        let shown = content
        delivered = nil
        lock.unlock()
        if let handler, let shown {
            handler(shown)
        }
    }
}
