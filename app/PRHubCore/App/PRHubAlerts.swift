import FeatureKit
import Foundation
import Observation
import PRKitCore
import UserNotifications

/// PRHub's notification delegate: a pr-worker alert shows while the app is in front, and its tap opens the PR
/// (docs/api.md, "Alerts") from the row it carried, which PRHubNotifications has usually fetched already. The hosted Worker's `signed_out` alert shows Sign in again, whether it arrives in front or
/// is tapped. A push of a feedback chat (FeedbackKit's own, `FeedbackPush`) shows the same way, and its tap opens that
/// chat. Nonisolated: the system names no thread for these calls.
public final class PRHubNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (PullRequestRef, PullRequestRow?) -> Void
    private let openFeedback: @MainActor @Sendable (String) -> Void
    /// A feedback chat's push arrived in front or was tapped: Feedback's badge counts from it.
    private let feedbackPush: @MainActor @Sendable (FeedbackPush) -> Void
    private let signedOut: @MainActor @Sendable () -> Void

    init(
        open: @escaping @MainActor @Sendable (PullRequestRef, PullRequestRow?) -> Void,
        openFeedback: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        feedbackPush: @escaping @MainActor @Sendable (FeedbackPush) -> Void = { _ in },
        signedOut: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.open = open
        self.openFeedback = openFeedback
        self.feedbackPush = feedbackPush
        self.signedOut = signedOut
    }

    /// Everything of an arrival but the system's types, so a test can play it.
    func arrived(_ userInfo: [AnyHashable: Any]) {
        guard let push = FeedbackPush(userInfo: userInfo) else {
            return
        }
        let feedbackPush = feedbackPush
        Task { @MainActor in feedbackPush(push) }
    }

    /// `reason: signed_out` (docs/api.md, "Errors on every other route").
    public static func isSignedOut(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["reason"] as? String == "signed_out"
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if Self.isSignedOut(notification.request.content.userInfo) {
            let signedOut = signedOut
            Task { @MainActor in signedOut() }
        }
        arrived(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if Self.isSignedOut(userInfo) {
            let signedOut = signedOut
            Task { @MainActor in signedOut() }
        }
        arrived(userInfo)
        let ref = PRPush(userInfo: userInfo)?.openedPullRequest
        let row = PRPush.row(in: userInfo)
        let action = response.actionIdentifier
        // Not Sendable, but only ever called once, on the main actor.
        nonisolated(unsafe) let done = completionHandler
        respond(action: action, pullRequest: ref, row: row, feedbackChat: FeedbackPush(userInfo: userInfo)?.chat) {
            done()
        }
    }

    /// The PR rows of the alerts still in Notification Center, newest first (`PRKitController.keepAlerts`).
    static func deliveredRows() async -> [PullRequestRow] {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .sorted { $0.date > $1.date }
            .compactMap { PRPush.row(in: $0.request.content.userInfo) }
    }

    /// Everything of a tap but the system's types, so a test can play it.
    func respond(
        action: String, pullRequest: PullRequestRef?, row: PullRequestRow? = nil, feedbackChat: String? = nil,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                if let pullRequest {
                    open(pullRequest, row)
                } else if let feedbackChat {
                    openFeedback(feedbackChat)
                }
            }
            completion()
        }
    }
}

/// Whether PRHub may show alerts, and when it offers to ask: once, after pairing with a Worker that pushes, with a
/// line on what they are for. "Not now" is kept until the next pairing; Settings can ask again.
@MainActor
@Observable
public final class PRHubAlertPermission {
    public enum Status: Equatable {
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

    public private(set) var status = Status.unknown
    /// Shows the explanation; the view sets it back.
    public var isOffering = false

    /// What the system says; the samples' permission asks the same one.
    @ObservationIgnored let center: Center
    @ObservationIgnored private let defaults: any PRKeyValueStore
    /// Each answer, as `alerts_answered`. Set by the environment, which owns it.
    @ObservationIgnored var usage: UsageAnalytics
    private static let declinedKey = "prhubAlertsDeclined"

    init(center: Center, defaults: any PRKeyValueStore) {
        usage = UsageAnalytics(hasProject: false, sink: nil, defaults: defaults)
        self.center = center
        self.defaults = defaults
    }

    public func reload() async {
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
    public func ask() async {
        isOffering = false
        _ = await center.request()
        await reload()
        usage.record(.alertsAnswered(status == .allowed ? .allowed : .denied))
    }

    /// "Not now".
    public func decline() {
        isOffering = false
        defaults.set(true, forKey: Self.declinedKey)
        usage.record(.alertsAnswered(.notNow))
    }

    /// A new pairing may offer again.
    func forgetDecline() {
        defaults.removeObject(forKey: Self.declinedKey)
    }
}
