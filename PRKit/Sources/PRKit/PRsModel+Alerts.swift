import Foundation
import PRKitCore

/// The alerts still in Notification Center, kept on the phone so a tap never waits on the network (docs/api.md,
/// "Alerts").
extension PRsModel {
    /// The most alerts one wake keeps: Notification Center rarely holds more PR alerts than this.
    static let keptAlerts = 30
    /// How long one alert's fetch may take at a wake: the Notification Service Extension's own limit.
    static let alertDeadline = Duration.seconds(6)

    /// The rows of the alerts still in Notification Center, newest first: each PR stays on the phone while its alert can
    /// be tapped. One the Notification Service Extension could not fetch (a timeout, no network then) is fetched now, and
    /// every one's files are noted again, so prune keeps them for `PRAlertedFiles.keptFor` from this wake. One at a time:
    /// the prefetch reads and writes `PRAlertedFiles` whole. Stops at `deadline`, so a background wake ends in time.
    @discardableResult
    func keepAlerts(_ rows: [PullRequestRow], deadline: Duration) async -> [PRPushPrefetch.Outcome] {
        guard samples == nil else {
            return []
        }
        let prefetch = PRPushPrefetch(client: client, files: mirror.files)
        let clock = ContinuousClock()
        let end = clock.now + deadline
        var outcomes: [PRPushPrefetch.Outcome] = []
        for row in rows.prefix(Self.keptAlerts) {
            let left = end - clock.now
            guard left > .zero, !Task.isCancelled else {
                break
            }
            await outcomes.append(prefetch.prefetch(row, deadline: min(left, Self.alertDeadline)))
        }
        return outcomes
    }
}
