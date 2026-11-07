import Foundation
import Observation
import UserNotifications

/// PRHub's notification delegate: a pr-worker alert shows while the app is in front, and its tap opens the PR
/// (docs/api.md, "Alerts"). Nonisolated: the system names no thread for these calls.
final class PRHubNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (PullRequestRef) -> Void

    init(open: @escaping @MainActor @Sendable (PullRequestRef) -> Void) {
        self.open = open
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let ref = PRPush(userInfo: response.notification.request.content.userInfo)?.openedPullRequest
        let action = response.actionIdentifier
        // Not Sendable, but only ever called once, on the main actor.
        nonisolated(unsafe) let done = completionHandler
        respond(action: action, pullRequest: ref) { done() }
    }

    /// Everything of a tap but the system's types, so a test can play it.
    func respond(
        action: String, pullRequest: PullRequestRef?, completion: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { @MainActor in
            if let pullRequest, action == UNNotificationDefaultActionIdentifier {
                open(pullRequest)
            }
            completion()
        }
    }
}

/// Whether PRHub may show alerts, and when it offers to ask: once, after pairing with a Worker that pushes, with a
/// line on what they are for. "Not now" is kept until the next pairing; Settings can ask again.
@MainActor
@Observable
final class PRHubAlertPermission {
    enum Status: Equatable {
        case unknown, notAsked, allowed, denied
    }

    /// What the system says, and asking it: `UNUserNotificationCenter` in the app, a stand-in in tests.
    struct Center: Sendable {
        var status: @Sendable () async -> UNAuthorizationStatus
        var request: @Sendable () async -> Bool

        static let live = Center(
            status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
            request: {
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            }
        )
    }

    private(set) var status = Status.unknown
    /// Shows the explanation; the view sets it back.
    var isOffering = false

    @ObservationIgnored private let center: Center
    @ObservationIgnored private let defaults: UserDefaults
    private static let declinedKey = "prhubAlertsDeclined"

    init(center: Center = .live, defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    func reload() async {
        status = switch await center.status() {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
    }

    /// After pairing, and at each config read: offers once the Worker pushes, if nobody has answered yet.
    func offerIfDue(workerPushes: Bool) async {
        await reload()
        guard workerPushes, status == .notAsked, !defaults.bool(forKey: Self.declinedKey) else {
            return
        }
        isOffering = true
    }

    /// "Turn on": the system's own question.
    func ask() async {
        isOffering = false
        _ = await center.request()
        await reload()
    }

    /// "Not now".
    func decline() {
        isOffering = false
        defaults.set(true, forKey: Self.declinedKey)
    }

    /// A new pairing may offer again.
    func forgetDecline() {
        defaults.removeObject(forKey: Self.declinedKey)
    }
}
