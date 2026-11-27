import os
@testable import PRKit
import SwiftUI
import Testing

/// The pull to refresh's watch (issue #55): a refresh's start and end, and whether the list came back to rest.
@MainActor
struct PRListRefreshWatchTests {
    private func watch(
        resting inset: CGFloat = 62, now: (() -> ContinuousClock.Instant)? = nil
    ) -> PRListRefreshWatch {
        let origin = ContinuousClock.now
        let watch = PRListRefreshWatch(now: now ?? { origin }, logger: Logger(.disabled))
        watch.geometry = PRListScrollRest(offsetY: -inset, insetTop: inset)
        return watch
    }

    @Test func aRefreshReportsItsStartAndHowItEnded() {
        var instant = ContinuousClock.now
        let watch = watch(now: { instant })
        #expect(watch.began(rows: 5) == .listRefreshStarted(rows: 5, screen: .list))
        #expect(watch.isRefreshing)
        instant += .milliseconds(250)
        guard case let .listRefreshFinished(finish) = watch.ended(.offline, rowsBefore: 5, rowsAfter: 5) else {
            Issue.record("not a finish")
            return
        }
        #expect(finish.outcome == .offline && finish.source == .cached && finish.rowsAfter == 5)
        #expect(finish.milliseconds == 250)
        #expect(!watch.isRefreshing)
    }

    @Test func aListBackAtRestIsNotStuck() {
        let watch = watch()
        _ = watch.began(rows: 3)
        _ = watch.ended(.ok, rowsBefore: 3, rowsAfter: 4)
        #expect(watch.stuck(isLoading: false) == nil)
    }

    @Test func aListLeftPulledDownIsStuck() {
        let watch = watch()
        _ = watch.began(rows: 3)
        _ = watch.ended(.ok, rowsBefore: 3, rowsAfter: 3)
        watch.geometry = PRListScrollRest(offsetY: -124, insetTop: 62)
        guard case let .listRefreshStuck(stuck) = watch.stuck(isLoading: true) else {
            Issue.record("not stuck")
            return
        }
        #expect(stuck.gap == 62 && stuck.offsetY == -124 && stuck.isLoading && stuck.scene == .active)
    }

    @Test func anInsetThatGrewAndStayedIsStuckToo() {
        let watch = watch()
        _ = watch.began(rows: 3)
        _ = watch.ended(.ok, rowsBefore: 3, rowsAfter: 3)
        // The offset matches the inset, but the inset kept the refresh control's room.
        watch.geometry = PRListScrollRest(offsetY: -122, insetTop: 122)
        guard case let .listRefreshStuck(stuck) = watch.stuck(isLoading: false) else {
            Issue.record("not stuck")
            return
        }
        #expect(stuck.gap == 60 && stuck.restingInsetTop == 62)
    }

    @Test func aFingerOnTheListIsNotAStuckList() {
        let watch = watch()
        _ = watch.began(rows: 3)
        _ = watch.ended(.ok, rowsBefore: 3, rowsAfter: 3)
        watch.geometry = PRListScrollRest(offsetY: -200, insetTop: 62)
        watch.scrolled(to: .dragged)
        #expect(watch.stuck(isLoading: false) == nil)
    }

    /// What the list was doing as its refresh ended (fb_74e943471c9df0b7): still gliding to the spinner's place 300 ms
    /// after the finger lifted, 2 pt short of it.
    @Test func aRefreshsEndSaysWhatTheScrollViewWasDoing() {
        var instant = ContinuousClock.now
        let watch = watch(now: { instant })
        watch.scrolled(to: .dragged)
        _ = watch.began(rows: 3)
        instant += .milliseconds(500)
        watch.scrolled(to: .gliding)
        instant += .milliseconds(300)
        watch.geometry = PRListScrollRest(offsetY: -124, insetTop: 122)
        guard case let .listRefreshFinished(finish) = watch.ended(.ok, rowsBefore: 3, rowsAfter: 3) else {
            Issue.record("not a finish")
            return
        }
        #expect(finish.scroll == PRRefreshEndScroll(
            state: .gliding, offsetY: -124, insetTop: 122, gap: 2, millisecondsSinceLift: 300
        ))
        #expect(finish.screen == .list && finish.milliseconds == 800)
    }

    @Test func aRefreshThatEndsUnderTheFingerHasNoTimeSinceItLifted() {
        let watch = watch()
        watch.scrolled(to: .dragged)
        watch.scrolled(to: .resting)
        watch.scrolled(to: .dragged)
        _ = watch.began(rows: 3)
        guard case let .listRefreshFinished(finish) = watch.ended(.ok, rowsBefore: 3, rowsAfter: 3) else {
            Issue.record("not a finish")
            return
        }
        #expect(finish.scroll.state == .dragged && finish.scroll.millisecondsSinceLift == nil)
    }

    /// Build 318 said `cancelled` for 13 pulls of 21: the pull's task, which SwiftUI cancels as the sync changes the
    /// screen, was taken for the outcome.
    @Test func aListPullEndsAsItsSyncDid() {
        #expect(PRListRefreshOutcome(.unchanged, isOnline: true) == .ok)
        #expect(PRListRefreshOutcome(.changed, isOnline: false) == .ok)
        #expect(PRListRefreshOutcome(.failed, isOnline: true) == .error)
        #expect(PRListRefreshOutcome(.failed, isOnline: false) == .offline)
    }

    @Test func aPRPagesWatchSaysItsScreenInEveryEvent() {
        let origin = ContinuousClock.now
        let watch = PRListRefreshWatch(screen: .pullRequest, now: { origin }, logger: Logger(.disabled))
        watch.geometry = PRListScrollRest(offsetY: -62, insetTop: 62)
        #expect(watch.began(rows: 0) == .listRefreshStarted(rows: 0, screen: .pullRequest))
        #expect(watch.backgrounded() == .listRefreshBackgrounded(milliseconds: 0, screen: .pullRequest))
        guard case let .listRefreshFinished(finish) = watch.ended(.error, rowsBefore: 0, rowsAfter: 0) else {
            Issue.record("not a finish")
            return
        }
        #expect(finish.screen == .pullRequest && finish.outcome == .error)
        watch.geometry = PRListScrollRest(offsetY: -122, insetTop: 62)
        guard case let .listRefreshStuck(stuck) = watch.stuck(isLoading: false) else {
            Issue.record("not stuck")
            return
        }
        #expect(stuck.screen == .pullRequest && stuck.gap == 60)
    }

    @Test func aQuickRefreshSpinsUntilTheShortestSpin() {
        #expect(!PullHold.mayEnd(after: .milliseconds(127), isInteracting: false))
        #expect(PullHold.mayEnd(after: PullHold.shortestSpin, isInteracting: false))
    }

    @Test func aRefreshUnderTheFingerWaitsForItToLetGo() {
        #expect(!PullHold.mayEnd(after: .seconds(2), isInteracting: true))
        #expect(PullHold.mayEnd(after: .seconds(2), isInteracting: false))
        #expect(PullHold.mayEnd(after: PullHold.longestHold, isInteracting: true))
    }

    @Test func goingToTheBackgroundIsReportedOnlyMidRefresh() {
        let watch = watch()
        #expect(watch.backgrounded() == nil)
        _ = watch.began(rows: 3)
        guard case .listRefreshBackgrounded = watch.backgrounded() else {
            Issue.record("not reported")
            return
        }
    }
}
