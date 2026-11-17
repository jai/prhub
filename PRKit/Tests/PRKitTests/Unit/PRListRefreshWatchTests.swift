@testable import PRKit
import SwiftUI
import Testing

/// The pull to refresh's watch (issue #55): a refresh's start and end, and whether the list came back to rest.
@MainActor
struct PRListRefreshWatchTests {
    private func watch(resting inset: CGFloat = 62) -> PRListRefreshWatch {
        let watch = PRListRefreshWatch()
        watch.geometry = PRListScrollRest(offsetY: -inset, insetTop: inset)
        return watch
    }

    @Test func aRefreshReportsItsStartAndHowItEnded() {
        let watch = watch()
        #expect(watch.began(rows: 5) == .listRefreshStarted(rows: 5))
        #expect(watch.isRefreshing)
        guard case let .listRefreshFinished(finish) = watch.ended(.offline, rowsBefore: 5, rowsAfter: 5) else {
            Issue.record("not a finish")
            return
        }
        #expect(finish.outcome == .offline && finish.source == .cached && finish.rowsAfter == 5)
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
        watch.isInteracting = true
        #expect(watch.stuck(isLoading: false) == nil)
    }

    @Test func aQuickRefreshSpinsUntilTheShortestSpin() {
        let watch = watch()
        _ = watch.began(rows: 3)
        let start = ContinuousClock.now
        #expect(!watch.mayEnd(at: start + .milliseconds(127)))
        #expect(watch.mayEnd(at: start + PRListRefreshWatch.shortestSpin + .milliseconds(1)))
    }

    @Test func aRefreshUnderTheFingerWaitsForItToLetGo() {
        let watch = watch()
        _ = watch.began(rows: 3)
        watch.isInteracting = true
        let start = ContinuousClock.now
        #expect(!watch.mayEnd(at: start + .seconds(2)))
        #expect(watch.mayEnd(at: start + PRListRefreshWatch.longestHold + .milliseconds(1)))
        watch.isInteracting = false
        #expect(watch.mayEnd(at: start + .seconds(2)))
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
