import Foundation
import os
import SwiftUI

/// How a pull to refresh of the PR list ended (`PRKitEvent.listRefreshFinished`).
public enum PRListRefreshOutcome: String, CaseIterable, Sendable {
    case ok, error, cancelled, offline
}

/// Where the rows on screen after a pull came from: the Worker's answer, or what the phone kept when it failed.
public enum PRListRefreshSource: String, CaseIterable, Sendable {
    case network, cached
}

/// The app's state when a refresh looked stuck.
public enum PRListSceneState: String, CaseIterable, Sendable {
    case active, inactive, background

    init(_ phase: ScenePhase) {
        self = switch phase {
        case .active: .active
        case .inactive: .inactive
        default: .background
        }
    }
}

/// A pull to refresh that ended (`PRKitEvent.listRefreshFinished`): counts and states only.
public struct PRListRefreshFinish: Equatable, Sendable {
    public let outcome: PRListRefreshOutcome
    public let milliseconds: Int
    public let rowsBefore: Int
    public let rowsAfter: Int
    public let source: PRListRefreshSource

    public init(
        outcome: PRListRefreshOutcome, milliseconds: Int, rowsBefore: Int, rowsAfter: Int, source: PRListRefreshSource
    ) {
        self.outcome = outcome
        self.milliseconds = milliseconds
        self.rowsBefore = rowsBefore
        self.rowsAfter = rowsAfter
        self.source = source
    }
}

/// The list not back at rest two seconds after a refresh ended (`PRKitEvent.listRefreshStuck`): the scroll view's
/// geometry then, in points, and what was still going on. `gap` is how far the top sits below where it rests, from the
/// offset or from an inset that grew during the refresh and did not shrink back.
public struct PRListRefreshStuck: Equatable, Sendable {
    public let gap: Int
    public let offsetY: Int
    public let insetTop: Int
    public let restingInsetTop: Int
    public let isRefreshing: Bool
    public let isLoading: Bool
    public let isInteracting: Bool
    public let scene: PRListSceneState

    public init(
        gap: Int, offsetY: Int, insetTop: Int, restingInsetTop: Int, isRefreshing: Bool, isLoading: Bool,
        isInteracting: Bool, scene: PRListSceneState
    ) {
        self.gap = gap
        self.offsetY = offsetY
        self.insetTop = insetTop
        self.restingInsetTop = restingInsetTop
        self.isRefreshing = isRefreshing
        self.isLoading = isLoading
        self.isInteracting = isInteracting
        self.scene = scene
    }
}

/// The list's scroll position and top inset, as `onScrollGeometryChange` reports them.
struct PRListScrollRest: Equatable {
    var offsetY: CGFloat
    var insetTop: CGFloat
}

/// Watches the PR list's pull to refresh (issue #55): when one starts and ends, how, and whether the list came back to
/// rest. Each event goes to the host (`PRKitEvent`) and to the system log, subsystem the host app's, category
/// `refresh`, so a sysdiagnose shows it too. Nothing about a PR is recorded.
@MainActor
final class PRListRefreshWatch {
    /// More than this far below rest, the list is not back.
    static let stuckPoints: CGFloat = 8
    /// How long after a refresh ends the list must be back at rest.
    static let settle: Duration = .seconds(2)
    /// UIKit leaves the list pulled down when its refresh ends under the finger or a moment after it began (build 303:
    /// a pull that joined a sync already running ended in 127 ms, and the list stayed 139 pt down). So a pull's
    /// spinner stays this long at least, and until the finger lets go.
    static let shortestSpin: Duration = .milliseconds(800)
    /// A finger that never lets go does not hold the spinner past this.
    static let longestHold: Duration = .seconds(10)

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PRKit", category: "refresh")
    var geometry: PRListScrollRest?
    var isInteracting = false
    /// The scene's state now (`onChange(of: scenePhase)`).
    var scene = ScenePhase.active
    private(set) var startedAt: ContinuousClock.Instant?
    private var restingInsetTop: CGFloat?

    var isRefreshing: Bool {
        startedAt != nil
    }

    func began(rows: Int) -> PRKitEvent {
        startedAt = .now
        restingInsetTop = geometry?.insetTop
        logger.info("refresh started rows=\(rows, privacy: .public)")
        return .listRefreshStarted(rows: rows)
    }

    func ended(_ outcome: PRListRefreshOutcome, rowsBefore: Int, rowsAfter: Int) -> PRKitEvent {
        let milliseconds = elapsedMilliseconds()
        startedAt = nil
        let source: PRListRefreshSource = outcome == .ok ? .network : .cached
        logger.info("""
        refresh finished outcome=\(outcome.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public) \
        rows=\(rowsBefore, privacy: .public)->\(rowsAfter, privacy: .public) \
        source=\(source.rawValue, privacy: .public)
        """)
        return .listRefreshFinished(PRListRefreshFinish(
            outcome: outcome, milliseconds: milliseconds, rowsBefore: rowsBefore, rowsAfter: rowsAfter, source: source
        ))
    }

    /// Whether the refresh may end now: it has spun `shortestSpin` and no finger is on the list, or it has waited
    /// `longestHold`. Asked before `ended`.
    func mayEnd(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let startedAt else {
            return true
        }
        let elapsed = now - startedAt
        return elapsed >= Self.longestHold || (elapsed >= Self.shortestSpin && !isInteracting)
    }

    /// The app left the foreground while a refresh ran.
    func backgrounded() -> PRKitEvent? {
        guard isRefreshing else {
            return nil
        }
        let milliseconds = elapsedMilliseconds()
        logger.info("refresh backgrounded ms=\(milliseconds, privacy: .public)")
        return .listRefreshBackgrounded(milliseconds: milliseconds)
    }

    /// Two seconds after a refresh ended: the list's state if it is not back at rest, else nil. A finger on the list
    /// is not a stuck list.
    func stuck(isLoading: Bool) -> PRKitEvent? {
        guard let geometry, !isInteracting else {
            return nil
        }
        let resting = restingInsetTop ?? geometry.insetTop
        let gap = max(-(geometry.offsetY + geometry.insetTop), geometry.insetTop - resting)
        guard gap > Self.stuckPoints else {
            return nil
        }
        let stuck = PRListRefreshStuck(
            gap: Int(gap.rounded()), offsetY: Int(geometry.offsetY.rounded()),
            insetTop: Int(geometry.insetTop.rounded()), restingInsetTop: Int(resting.rounded()),
            isRefreshing: isRefreshing, isLoading: isLoading,
            isInteracting: isInteracting, scene: PRListSceneState(scene)
        )
        logger.error("""
        refresh stuck gap=\(stuck.gap, privacy: .public) offset=\(stuck.offsetY, privacy: .public) \
        inset=\(stuck.insetTop, privacy: .public) resting=\(stuck.restingInsetTop, privacy: .public) \
        refreshing=\(stuck.isRefreshing, privacy: .public) loading=\(stuck.isLoading, privacy: .public) \
        scene=\(stuck.scene.rawValue, privacy: .public)
        """)
        return .listRefreshStuck(stuck)
    }

    private func elapsedMilliseconds() -> Int {
        guard let startedAt else {
            return 0
        }
        let elapsed = ContinuousClock.now - startedAt
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
