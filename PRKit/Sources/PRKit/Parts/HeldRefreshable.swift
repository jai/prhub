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
    /// finishes. On the Mac, which has no pull, the toolbar's Refresh and ⌘R.
    func heldRefreshable(_ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(HeldRefreshable(action: action))
    }
}

private struct HeldRefreshable: ViewModifier {
    let action: @MainActor @Sendable () async -> Void
    @State private var finger = Finger()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                finger.isDown = phase == .interacting || phase == .tracking
            }
            .refreshableWithCommand { [action, finger] in
                let start = ContinuousClock.now
                await Task { @MainActor in await action() }.value
                await PullHold.wait(since: start) { finger.isDown }
            }
    }
}

/// A finger on the scroll view, read as the spinner waits.
@MainActor
private final class Finger {
    var isDown = false
}
