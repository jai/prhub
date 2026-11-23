import Foundation
@testable import PRKit
import PRKitTestSupport
import SwiftUI
import Testing

/// How a PR's screens stack: the diff pushed over its PR, the Review shortcut, links to a PR's files, the wide layout's
/// list beside the PR, and the diff's panel.
@MainActor
struct PRNavigationTests {
    private let kit: PRKitController

    init() {
        let host = PRKitControllerTests.Host()
        kit = PRKitController(host: host, storage: .inMemory(), network: PRNetwork(isOnline: true))
    }

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

    #if os(macOS)
        /// The Mac's stack binds `macPath`: Back takes screens off `routes`, and a tab coming back (path emptied, then set
        /// again) brings them back.
        @Test func theMacPathBacksOffAndComesBackAsTheRoutes() {
            let navigation = PRNavigation()
            let session = kit.model.session(for: ref, source: .link)
            navigation.routes = PRRoute.opening(session, showsDiff: true)
            #expect(navigation.macPath.count == 2)

            navigation.macPath.removeLast()
            #expect(navigation.routes == [.pullRequest(session)], "Back from the diff is the PR")

            let leftOpen = navigation.macPath
            navigation.macPath = NavigationPath()
            #expect(navigation.routes.isEmpty)
            navigation.macPath = leftOpen
            #expect(navigation.routes == [.pullRequest(session)], "coming back to the tab shows the PR again")
        }
    #endif

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

    @Test func aReviewSentFromTheDiffGoesBackToTheList() {
        var routes: [PRRoute] = []
        let stack = PRStack.routes(Binding(get: { routes }, set: { routes = $0 }))
        PullRequestOpener(model: kit.model, stack: stack).review(ref)
        #expect(routes.count == 2)
        stack.leaveDiff()
        #expect(routes.isEmpty)
    }

    /// A screen SwiftUI redraws while it is being told of the change reads the screens after it: it is not told again
    /// (the iPad's split view kept a PR up after its review).
    @Test func aScreenRedrawnAsTheRoutesChangeReadsTheNewOnes() {
        let navigation = kit.navigation
        navigation.routes = PRRoute.opening(kit.model.session(for: ref), showsDiff: true)
        var redrawn: [Int] = []
        withObservationTracking {
            _ = navigation.routes
        } onChange: {
            MainActor.assumeIsolated { redrawn.append(navigation.routes.count) }
        }
        PRStack.routes(Binding(get: { navigation.routes }, set: { navigation.routes = $0 })).leaveDiff()
        #expect(redrawn == [0], "told once, with the PR already gone")
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

    /// A loaded PR in a sample set that keeps nothing, so marking a file viewed stays on the screen.
    private func loadedSession(diff text: String) throws -> PRSession {
        let samples = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: false)
        let model = PRsModel(
            client: PRViewerClient(access: .offline, transport: UnexpectedTransport()), samples: samples,
            storage: .inMemory(), network: PRNetwork(isOnline: true)
        )
        let detail = try PullRequestDetail.decode(Data(PRTestPayload.detail(id: "PR_7").utf8))
        return PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: DiffDocument(data: Data(text.utf8))),
            tappedAt: 0, model: model
        )
    }

    @Test func viewedFromTheKeyboardMarksTheFileOnTop() throws {
        let text = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
        let session = try loadedSession(diff: text)
        let files = DiffRows(document: DiffDocument(data: Data(text.utf8)), threads: []).files
        let before = session.viewedFiles
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before.union(["a"]))
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before)
    }

    @Test func markingAFileViewedTwiceKeepsItViewed() throws {
        let session = try loadedSession(diff: "diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+y\n")
        session.setViewed(true, path: "a")
        session.setViewed(true, path: "a")
        #expect(session.viewedFiles.contains("a"))
        session.setViewed(false, path: "a")
        session.setViewed(false, path: "a")
        #expect(!session.viewedFiles.contains("a"))
    }
}
