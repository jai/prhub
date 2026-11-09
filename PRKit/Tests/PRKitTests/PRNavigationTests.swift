import Foundation
import SwiftUI
import Testing
@testable import PRKit

/// How a PR's screens stack: the diff pushed over its PR, the Review shortcut, links to a PR's files, the wide layout's
/// list beside the PR, and the diff's panel.
@MainActor
struct PRNavigationTests {
    private let kit = PRKitController(host: PRKitControllerTests.Host())
    private let ref = PullRequestRef(repo: "acme/api", number: 7)

    @Test func aLinkToAPRsFilesOrChangesShowsItsDiff() {
        let files = PRLinkParser.link(in: "https://github.com/acme/api/pull/7/files#diff-1")
        #expect(files == PRLink(ref: ref, showsDiff: true))
        #expect(PRLinkParser.link(in: "https://github.com/acme/api/pull/7/changes")?.showsDiff == true)
        #expect(PRLinkParser.link(in: "https://github.com/acme/api/pull/7/commits")?.showsDiff == false)
        #expect(PRLinkParser.link(in: "https://github.com/acme/api/pull/7")?.showsDiff == false)
        #expect(PRLinkParser.link(in: "acme/api#7") == PRLink(ref: ref))
        #expect(kit.open(text: "https://github.com/acme/api/pull/7/files"))
        #expect(kit.navigation.pending?.link == PRLink(ref: ref, showsDiff: true))
    }

    @Test func theReviewShortcutPushesThePRWithItsDiffOnTopAndKeyLinesOpen() {
        var routes: [PRRoute] = []
        let opener = PullRequestOpener(
            model: kit.model, stack: .routes(Binding(get: { routes }, set: { routes = $0 }))
        )
        opener.review(ref)
        guard case let .pullRequest(session) = routes.first, routes.count == 2, routes.last == .diff(session) else {
            Issue.record("expected the PR, then its diff: \(routes)")
            return
        }
        session.diffAppeared()
        #expect(session.isShowingNavigator && session.navigatorPage == .keyLines)

        PRStack.routes(Binding(get: { routes }, set: { routes = $0 })).back()
        #expect(routes == [.pullRequest(session)], "Back from the diff is the PR")
    }

    @Test func aPRsOwnReviewChangesOpensKeyLinesUnlessALinesCommentIsOpen() {
        var routes: [PRRoute] = []
        let stack = PRStack.routes(Binding(get: { routes }, set: { routes = $0 }))
        let opener = PullRequestOpener(model: kit.model, stack: stack)
        opener.open(PRLink(ref: ref))
        let session = routes[0].session
        opener.reviewChanges(of: session)
        #expect(routes == [.pullRequest(session), .diff(session)])
        session.diffAppeared()
        #expect(session.isShowingNavigator && session.navigatorPage == .keyLines)

        stack.back()
        session.diffDisappeared()
        session.isShowingNavigator = false
        session.composingLine = 3
        opener.reviewChanges(of: session)
        session.diffAppeared()
        #expect(!session.isPanelOpen, "a half-written comment stays in view")
    }

    @Test func aPRsFilesChangedPushesTheDiffWithThePanelShut() {
        var routes: [PRRoute] = []
        let stack = PRStack.routes(Binding(get: { routes }, set: { routes = $0 }))
        let opener = PullRequestOpener(model: kit.model, stack: stack)
        opener.open(PRLink(ref: ref))
        let session = routes[0].session
        session.hasShownDescription = true
        opener.showDiff(of: session)
        #expect(routes == [.pullRequest(session), .diff(session)])
        session.diffAppeared()
        #expect(!session.isPanelOpen)
        stack.backFromPullRequest()
        #expect(routes.isEmpty)
    }

    @Test func theWideListReplacesThePROnShowAndTheDetailStacksOverIt() {
        let navigation = kit.navigation
        let list = PRStack.replacing(Binding(get: { navigation.routes }, set: { navigation.routes = $0 }))
        let first = kit.model.session(for: ref)
        list.show(PRRoute.opening(first, showsDiff: true))
        #expect(navigation.selected === first && navigation.detailRoutes == [.diff(first)] && navigation.showsDiff)

        let second = kit.model.session(for: PullRequestRef(repo: "acme/api", number: 8))
        list.show([.pullRequest(second)])
        #expect(navigation.selected === second && navigation.detailRoutes.isEmpty && !navigation.showsDiff)

        navigation.detailRoutes = [.diff(second)]
        #expect(navigation.routes == [.pullRequest(second), .diff(second)])
        #expect(kit.openCount == 2)
    }

    @Test func thePanelIsAColumnOnlyWhereARegularWidthHasRoomForTheDiffBesideIt() {
        let room = PanelStyle.columnWidth + PanelStyle.diffWidth
        #expect(PRPanelPlacement.fitting(width: room, isRegularWidth: true) == .column)
        #expect(PRPanelPlacement.fitting(width: room - 1, isRegularWidth: true) == .overlay)
        #expect(PRPanelPlacement.fitting(width: room * 2, isRegularWidth: false) == .overlay)
    }

    @Test func aPickInTheColumnKeepsItOpenAndOverTheDiffClosesIt() {
        let session = kit.model.session(for: ref)
        session.openPanel()
        session.show(file: "a.swift")
        #expect(!session.isShowingNavigator, "over the diff, a pick shows its place")

        session.placePanel(.column)
        #expect(session.isPanelOpen)
        session.show(file: "a.swift")
        #expect(session.isPanelOpen, "beside the diff, it stays")
        session.togglePanel()
        #expect(!session.isPanelOpen)

        session.placePanel(.overlay)
        #expect(!session.isPanelOpen, "narrowed, it doesn't cover the code")
    }

    @Test func nextAndPreviousFileGoRoundFromTheFileOnTop() {
        let session = kit.model.session(for: ref)
        let text = ["a", "b", "c"].map { "diff --git a/\($0) b/\($0)\n--- a/\($0)\n+++ b/\($0)\n@@ -1 +1 @@\n-x\n+y\n" }
        let files = DiffRows(document: DiffDocument(data: Data(text.joined().utf8)), threads: []).files
        #expect(files.map(\.path) == ["a", "b", "c"])
        session.stepFile(by: 1, in: files)
        #expect(session.topFile == 0 && session.jump?.path == "a")
        session.topFile = 2
        session.stepFile(by: 1, in: files)
        #expect(session.topFile == 0)
        session.stepFile(by: -1, in: files)
        #expect(session.topFile == 2 && session.jump?.path == "c")
    }

    @Test func viewedFromTheKeyboardMarksTheFileOnTop() async throws {
        let samples = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: false)
        let kit = PRKitController(host: PRKitControllerTests.Host(samples: samples))
        let text = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
        let document = DiffDocument(data: Data(text.utf8))
        let detail = try PullRequestDetail.decode(FixtureContractTests.data("detail.json"))
        let session = PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: document), tappedAt: 0, model: kit.model
        )
        let files = DiffRows(document: document, threads: []).files
        let before = session.viewedFiles
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before.union(["a"]))
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before)
    }
}
