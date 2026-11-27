import Foundation
import os
import SwiftUI

/// How a pull to refresh ended (`PRKitEvent.listRefreshFinished`). `cancelled`: the read itself was cancelled. A pull's
/// own task says nothing here: SwiftUI cancels it whenever the refresh changes what is on screen, and the read goes on.
public enum PRListRefreshOutcome: String, CaseIterable, Sendable {
    case ok, error, cancelled, offline

    /// How the PR list's pull ended: what its sync said.
    init(_ synced: PRSyncOutcome, isOnline: Bool) {
        self = switch synced {
        case .changed, .unchanged: .ok
        case .failed: isOnline ? .error : .offline
        }
    }
}

/// The screen whose pull to refresh is watched.
public enum PRRefreshScreen: String, CaseIterable, Sendable {
    case list
    case pullRequest = "pr"
}

/// What the scroll view was doing at the moment a refresh ended: at rest, moving with no finger on it, or under one.
public enum PRRefreshScrollState: String, CaseIterable, Sendable {
    case resting, gliding, dragged

    init(_ phase: ScrollPhase) {
        self = switch phase {
        case .idle: .resting
        case .interacting, .tracking: .dragged
        default: .gliding
        }
    }
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

/// The scroll view at the moment a refresh ended, in points: what it was doing, where it was, how far its top sat
/// below rest with the spinner's room counted as rest, and how long before that the finger had lifted (nil: it had
/// not, or it was back on the list).
public struct PRRefreshEndScroll: Equatable, Sendable {
    public let state: PRRefreshScrollState
    public let offsetY: Int
    public let insetTop: Int
    public let gap: Int
    public let millisecondsSinceLift: Int?

    public init(state: PRRefreshScrollState, offsetY: Int, insetTop: Int, gap: Int, millisecondsSinceLift: Int?) {
        self.state = state
        self.offsetY = offsetY
        self.insetTop = insetTop
        self.gap = gap
        self.millisecondsSinceLift = millisecondsSinceLift
    }
}

/// A pull to refresh that ended (`PRKitEvent.listRefreshFinished`): counts and states only.
public struct PRListRefreshFinish: Equatable, Sendable {
    public let screen: PRRefreshScreen
    public let outcome: PRListRefreshOutcome
    public let milliseconds: Int
    public let rowsBefore: Int
    public let rowsAfter: Int
    public let source: PRListRefreshSource
    public let scroll: PRRefreshEndScroll

    public init(
        screen: PRRefreshScreen = .list, outcome: PRListRefreshOutcome, milliseconds: Int, rowsBefore: Int,
        rowsAfter: Int, source: PRListRefreshSource, scroll: PRRefreshEndScroll
    ) {
        self.screen = screen
        self.outcome = outcome
        self.milliseconds = milliseconds
        self.rowsBefore = rowsBefore
        self.rowsAfter = rowsAfter
        self.source = source
        self.scroll = scroll
    }
}

/// The list not back at rest two seconds after a refresh ended (`PRKitEvent.listRefreshStuck`): the scroll view's
/// geometry then, in points, and what was still going on. `gap` is how far the top sits below where it rests, from the
/// offset or from an inset that grew during the refresh and did not shrink back.
public struct PRListRefreshStuck: Equatable, Sendable {
    public let screen: PRRefreshScreen
    public let gap: Int
    public let offsetY: Int
    public let insetTop: Int
    public let restingInsetTop: Int
    public let isRefreshing: Bool
    public let isLoading: Bool
    public let isInteracting: Bool
    public let scene: PRListSceneState

    public init(
        screen: PRRefreshScreen = .list, gap: Int, offsetY: Int, insetTop: Int, restingInsetTop: Int,
        isRefreshing: Bool, isLoading: Bool, isInteracting: Bool, scene: PRListSceneState
    ) {
        self.screen = screen
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

/// Watches a pull to refresh, the PR list's or a PR page's (issue #55): when one starts and ends, how, what the scroll
/// view was doing at that moment, and whether it came back to rest. Each event goes to the host (`PRKitEvent`) and to the system log, subsystem the host app's, category
/// `refresh`, so a sysdiagnose shows it too. Nothing about a PR is recorded.
@MainActor
final class PRListRefreshWatch {
    /// More than this far below rest, the list is not back.
    static let stuckPoints: CGFloat = 8
    /// How long after a refresh ends the list must be back at rest.
    static let settle: Duration = .seconds(2)

    let screen: PRRefreshScreen
    private let logger: Logger
    private let now: () -> ContinuousClock.Instant
    var geometry: PRListScrollRest?
    /// What the scroll view is doing now (`onScrollPhaseChange`, through `scrolled(to:)`).
    private(set) var scroll = PRRefreshScrollState.resting
    private var liftedAt: ContinuousClock.Instant?
    /// The scene's state now (`onChange(of: scenePhase)`).
    var scene = ScenePhase.active
    private(set) var startedAt: ContinuousClock.Instant?
    private var restingInsetTop: CGFloat?

    init(
        screen: PRRefreshScreen = .list, now: @escaping () -> ContinuousClock.Instant = { .now },
        logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PRKit", category: "refresh")
    ) {
        self.screen = screen
        self.now = now
        self.logger = logger
    }

    /// A finger is on the scroll view.
    var isInteracting: Bool {
        scroll == .dragged
    }

    /// The scroll view's phase changed. The moment a finger leaves it is kept, for `ended`.
    func scrolled(to state: PRRefreshScrollState) {
        if scroll == .dragged, state != .dragged {
            liftedAt = now()
        }
        scroll = state
    }

    var isRefreshing: Bool {
        startedAt != nil
    }

    func began(rows: Int) -> PRKitEvent {
        startedAt = now()
        restingInsetTop = geometry?.insetTop
        logger.info("refresh started screen=\(self.screen.rawValue, privacy: .public) rows=\(rows, privacy: .public)")
        return .listRefreshStarted(rows: rows, screen: screen)
    }

    func ended(_ outcome: PRListRefreshOutcome, rowsBefore: Int, rowsAfter: Int) -> PRKitEvent {
        let milliseconds = elapsedMilliseconds()
        startedAt = nil
        let source: PRListRefreshSource = outcome == .ok ? .network : .cached
        let end = endScroll()
        logger.info("""
        refresh finished screen=\(self.screen.rawValue, privacy: .public) \
        outcome=\(outcome.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public) \
        rows=\(rowsBefore, privacy: .public)->\(rowsAfter, privacy: .public) \
        source=\(source.rawValue, privacy: .public) scroll=\(end.state.rawValue, privacy: .public) \
        offset=\(end.offsetY, privacy: .public) inset=\(end.insetTop, privacy: .public) \
        gap=\(end.gap, privacy: .public) sinceLift=\(end.millisecondsSinceLift ?? -1, privacy: .public)
        """)
        return .listRefreshFinished(PRListRefreshFinish(
            screen: screen, outcome: outcome, milliseconds: milliseconds, rowsBefore: rowsBefore,
            rowsAfter: rowsAfter, source: source, scroll: end
        ))
    }

    /// The scroll view now, as a refresh ends.
    private func endScroll() -> PRRefreshEndScroll {
        let offset = geometry?.offsetY ?? 0
        let inset = geometry?.insetTop ?? 0
        let sinceLift = scroll == .dragged ? nil : liftedAt.map { Self.milliseconds(now() - $0) }
        return PRRefreshEndScroll(
            state: scroll, offsetY: Int(offset.rounded()), insetTop: Int(inset.rounded()),
            gap: Int((-(offset + inset)).rounded()), millisecondsSinceLift: sinceLift
        )
    }

    /// The app left the foreground while a refresh ran.
    func backgrounded() -> PRKitEvent? {
        guard isRefreshing else {
            return nil
        }
        let milliseconds = elapsedMilliseconds()
        logger.info("refresh backgrounded ms=\(milliseconds, privacy: .public)")
        return .listRefreshBackgrounded(milliseconds: milliseconds, screen: screen)
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
            screen: screen, gap: Int(gap.rounded()), offsetY: Int(geometry.offsetY.rounded()),
            insetTop: Int(geometry.insetTop.rounded()), restingInsetTop: Int(resting.rounded()),
            isRefreshing: isRefreshing, isLoading: isLoading,
            isInteracting: isInteracting, scene: PRListSceneState(scene)
        )
        logger.error("""
        refresh stuck screen=\(self.screen.rawValue, privacy: .public) gap=\(stuck.gap, privacy: .public) offset=\(stuck.offsetY, privacy: .public) \
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
        return Self.milliseconds(now() - startedAt)
    }

    private static func milliseconds(_ elapsed: Duration) -> Int {
        Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
