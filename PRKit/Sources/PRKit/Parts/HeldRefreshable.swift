import SwiftUI

/// When a pull to refresh may end. UIKit leaves a scroll view pulled down when its refresh ends under the finger or a
/// moment after it began (build 303: a pull that joined a sync already running ended in 127 ms, and the PR list stayed
/// 139 pt down). So the spinner stays `shortestSpin` at least and until the finger lets go, but no longer than
/// `longestHold`.
enum PullHold {
    static let shortestSpin: Duration = .milliseconds(800)
    static let longestHold: Duration = .seconds(10)

    static func mayEnd(after elapsed: Duration, isInteracting: Bool) -> Bool {
        elapsed >= longestHold || (elapsed >= shortestSpin && !isInteracting)
    }

    /// Waits until `mayEnd`, in a task of its own: SwiftUI can cancel a pull's task as the page changes under it, and a
    /// cancelled sleep would end the spinner at once.
    @MainActor
    static func wait(since start: ContinuousClock.Instant, isInteracting: @escaping @MainActor () -> Bool) async {
        await Task { @MainActor in
            while !mayEnd(after: .now - start, isInteracting: isInteracting()) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }.value
    }
}

extension View {
    /// Pull to refresh held by `PullHold`, with its work in a task of its own too, so a pull SwiftUI cancels still
    /// finishes. On the Mac, which has no pull, the toolbar's Refresh and ⌘R. A PR page's, watched as the PR list's
    /// is (`PRListRefreshWatch`): `action` says how the refresh ended and `report` takes each event.
    func heldRefreshable(
        report: @escaping @MainActor @Sendable (PRKitEvent) -> Void,
        action: @escaping @MainActor @Sendable () async -> PRListRefreshOutcome
    ) -> some View {
        modifier(HeldRefreshable(report: report, action: action))
    }
}

private struct HeldRefreshable: ViewModifier {
    let report: @MainActor @Sendable (PRKitEvent) -> Void
    let action: @MainActor @Sendable () async -> PRListRefreshOutcome
    @State private var watch = PRListRefreshWatch(screen: .pullRequest)
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: PRListScrollRest.self) { geometry in
                PRListScrollRest(offsetY: geometry.contentOffset.y, insetTop: geometry.contentInsets.top)
            } action: { _, rest in
                watch.geometry = rest
            }
            .onScrollPhaseChange { _, phase in
                watch.scrolled(to: PRRefreshScrollState(phase))
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                watch.scene = phase
                if phase == .background, let event = watch.backgrounded() {
                    report(event)
                }
            }
            .refreshableWithCommand { [action, report, watch] in
                await Self.pull(action, watch: watch, report: report)
            }
    }

    @MainActor
    private static func pull(
        _ action: @escaping @MainActor @Sendable () async -> PRListRefreshOutcome, watch: PRListRefreshWatch,
        report: @escaping @MainActor @Sendable (PRKitEvent) -> Void
    ) async {
        let start = ContinuousClock.now
        report(watch.began(rows: 0))
        let outcome = await Task { @MainActor in await action() }.value
        await PullHold.wait(since: start) { watch.isInteracting }
        report(watch.ended(outcome, rowsBefore: 0, rowsAfter: 0))
        Task { @MainActor in
            try? await Task.sleep(for: PRListRefreshWatch.settle)
            if let event = watch.stuck(isLoading: false) {
                report(event)
            }
        }
    }
}
