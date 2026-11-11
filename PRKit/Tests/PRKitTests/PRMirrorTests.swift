import PRKitNetwork
@testable import PRKit
import Foundation
import SwiftUI
import Testing

struct PRMirrorTests {
    private func row(_ number: Int, revision: String) -> PullRequestRow {
        PullRequestRow(
            repo: "o/r", number: number, title: "t", head: "h", revision: revision, diff: .ready, detail: "d",
            status: nil
        )
    }

    @Test func theReviewListHasPendingThenRecentlyReviewedAndMyPRsHasNoSections() {
        let row = { (number: Int, list: String) in
            PullRequestRow(
                repo: "o/r", number: number, title: "PR", head: "h", revision: "r", diff: .ready, detail: "d",
                status: .init(
                    list: list, author: "a", checks: "passing", review: "none", merge: "clean", jaiReview: nil,
                    jaiReviewedAt: nil
                )
            )
        }
        let ids = { (page: PRListPage, rows: [PullRequestRow]) in page.entries(rows).map(\.id) }

        #expect(ids(.review, [row(1, "reviewed"), row(2, "review")])
            == ["header:Review Pending", "o/r#2", "header:Recently Reviewed", "o/r#1"])
        #expect(ids(.review, [row(2, "review")]) == ["header:Review Pending", "o/r#2"])
        #expect(ids(.mine, [row(3, "mine")]) == ["o/r#3"])
    }

    @Test func askChatReadsWhatTheWorkerSends() throws {
        let json = #"""
        {"messages":[{"id":"1","role":"you","text":"why?","anchor":"a.tf:3"},{"id":"2","role":"agent","text":"because","anchor":null}],
         "isWorking":true,"activity":"Reading a.tf","problem":null,"costCents":16}
        """#
        let chat = try JSONDecoder().decode(PRAskChat.self, from: Data(json.utf8))
        #expect(chat.messages.map(\.isJai) == [true, false])
        #expect(chat.messages.first?.anchor == "a.tf:3")
        #expect(chat.isWorking && chat.costCents == 16)
    }

    @MainActor @Test func backFromAPRInItsOwnTabIsTheListAndFromAnotherTabIsOneStep() {
        var path = NavigationPath(["first", "second"])
        let binding = Binding(get: { path }, set: { path = $0 })

        PRStack.path(binding, backGoesToRoot: false).backFromPullRequest()
        #expect(path.count == 1)

        path.append("second")
        PRStack.path(binding, backGoesToRoot: true).backFromPullRequest()
        #expect(path.isEmpty)

        PRStack.path(binding, backGoesToRoot: false).backFromPullRequest()
        #expect(path.isEmpty)
    }

    @Test func aReviewWaitingOnJaisOwnChangeRequestComesFirst() {
        let row = { (number: Int, list: String, review: String?) in
            PullRequestRow(
                repo: "o/r", number: number, title: "PR", head: "h", revision: "r", diff: .ready, detail: "d",
                status: .init(
                    list: list, author: "a", checks: "passing", review: "approved", merge: "blocked", jaiReview: review,
                    jaiReviewedAt: nil
                )
            )
        }
        let rows = [
            row(1, "review", nil), row(2, "reviewed", "changes_requested"), row(3, "review", "changes_requested"),
            row(4, "review", "approved"), row(5, "review", "changes_requested"),
        ]

        #expect(PRListPage.ordered(rows).map(\.number) == [3, 5, 1, 2, 4])
    }

    @Test func aMergedRowReadsAsMergedWithNothingStillToDo() {
        let row = { (number: Int, list: String) in
            PullRequestRow(
                repo: "o/r", number: number, title: "PR", head: "h", revision: "r", diff: .ready, detail: "d",
                status: .init(
                    list: list, author: "jai", checks: "none", review: "none", merge: "unknown", jaiReview: nil,
                    jaiReviewedAt: nil
                )
            )
        }
        #expect(PRListPage.review.entries([row(2, "merged")]).map(\.id) == ["o/r#2"])
        #expect(row(2, "merged").isMerged)
        #expect(!row(2, "merged").isReviewRequest)
        #expect(row(2, "merged").listPullRequest.status.state == .merged)
        #expect(row(2, "merged").listPullRequest.status.signalMarks.isEmpty)
    }

    @Test func reviewsPastTheirSLAComeFirstLongestOverdueOnTop() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = { (number: Int, list: String, due: TimeInterval?, review: String?) in
            PullRequestRow(
                repo: "o/r", number: number, title: "PR", head: "h", revision: "r", diff: .ready, detail: "d",
                status: .init(
                    list: list, author: "a", checks: "passing", review: "required", merge: "blocked", jaiReview: review,
                    jaiReviewedAt: nil,
                    reviewDueAt: due.map { now.addingTimeInterval($0).formatted(.iso8601) }
                )
            )
        }
        let rows = [
            row(1, "review", 3_600, nil), row(2, "review", -3_600, nil), row(3, "review", nil, "changes_requested"),
            row(4, "review", -86_400, nil), row(5, "reviewed", -90_000, "approved"),
        ]

        #expect(PRListPage.ordered(rows, now: now).map(\.number) == [4, 2, 3, 1, 5])
        #expect(rows[3].listPullRequest.pastSLA(now: now) != nil)
        #expect(rows[0].listPullRequest.pastSLA(now: now) == nil)
        #expect(rows[4].listPullRequest.pastSLA(now: now) == nil)
    }

    @Test func aReviewNotYetLateComesInTheOrderItWasAskedAndCanBeSortedEitherWay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = { (number: Int, repo: String, author: String, list: String, askedHoursAgo: Double?) in
            PullRequestRow(
                repo: repo, number: number, title: "PR", head: "h", revision: "r", diff: .ready, detail: "d",
                status: .init(
                    list: list, author: author, checks: "passing", review: "required", merge: "blocked",
                    jaiReview: nil, jaiReviewedAt: nil,
                    requestedAt: askedHoursAgo.map { now.addingTimeInterval(-$0 * 3_600).formatted(.iso8601) },
                    reviewDueAt: now.addingTimeInterval(86_400).formatted(.iso8601)
                )
            )
        }
        let rows = [
            row(1, "o/a", "mona", "review", 2), row(2, "o/b", "ada", "review", 9), row(3, "o/a", "ada", "reviewed", nil),
            row(4, "o/b", "mona", "review", nil), row(5, "o/a", "ada", "review", 30),
        ]

        #expect(PRListPage.ordered(rows, now: now).map(\.number) == [5, 2, 1, 3, 4])
        #expect(PRListPage.ordered(rows, by: .newest, now: now).map(\.number) == [1, 2, 5, 3, 4])

        let sorted = PRListPage.ordered(rows, now: now)
        #expect(PRListPage.review.entries(sorted, grouping: .repo).map(\.id) == [
            "header:o/a", "o/a#5", "o/a#1", "header:o/b", "o/b#2", "o/b#4", "header:Recently Reviewed", "o/a#3",
        ])
        #expect(PRListPage.review.entries(sorted, grouping: .author).map(\.id) == [
            "header:ada", "o/a#5", "o/b#2", "header:mona", "o/a#1", "o/b#4", "header:Recently Reviewed", "o/a#3",
        ])
    }

    @Test func withNoSLAFromTheWorkerAReviewIsDueOneWorkingDayAfterItCouldBeSeen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 7 * 3_600))
        let week = ReviewWeek(calendar: calendar)
        let date = { (text: String) in try Date(text, strategy: .iso8601) }
        // Thursday 10:00 local: Friday 10:00. Friday 10:00: Monday 10:00.
        #expect(week.dueAt(requestedAt: try date("2026-11-05T03:00:00Z")) == (try date("2026-11-06T03:00:00Z")))
        #expect(week.dueAt(requestedAt: try date("2026-11-06T03:00:00Z")) == (try date("2026-11-09T03:00:00Z")))
        // Thursday 20:00: the day starts Friday 09:00, so Monday 09:00. Saturday: Tuesday 09:00. Thursday 07:00:
        // Friday 09:00.
        #expect(week.dueAt(requestedAt: try date("2026-11-05T13:00:00Z")) == (try date("2026-11-09T02:00:00Z")))
        #expect(week.dueAt(requestedAt: try date("2026-11-07T05:00:00Z")) == (try date("2026-11-10T02:00:00Z")))
        #expect(week.dueAt(requestedAt: try date("2026-11-05T00:00:00Z")) == (try date("2026-11-06T02:00:00Z")))
    }

    @Test func theOrgFilterStartsAtTheHostsOrgsAndSurvivesSaving() {
        var filter = PROrgFilter(selected: ["acme"])
        let work = PullRequestRow(
            repo: "acme/app", number: 1, title: "t", head: "h", revision: "a", diff: .ready, detail: "d",
            status: nil
        )
        #expect(filter.shows(work))
        #expect(!filter.shows(row(2, revision: "a")))
        filter.toggle("o")
        #expect(filter.shows(row(2, revision: "a")))
        filter.toggle("acme")
        #expect(!filter.shows(work))
        #expect(PROrgFilter(rawValue: filter.rawValue) == filter)
    }

    @Test func aReviewJaiAnsweredShowsAsHisAndIsNotAskedAgain() throws {
        let status = PullRequestRow.Status(
            list: "reviewed", author: "ann", checks: "passing", review: "approved", merge: "clean",
            jaiReview: "approved", jaiReviewedAt: "2026-11-01T01:00:00Z"
        )
        let row = PullRequestRow(
            repo: "o/r", number: 1, title: "t", head: "h", revision: "a", diff: .ready, detail: "d", status: status
        )
        let pullRequest = row.listPullRequest
        #expect(pullRequest.isAnswered == true)
        #expect(pullRequest.jaiReview == .approved)
        #expect(pullRequest.jaiReviewRequested == false)
        #expect(pullRequest.jaiReviewedAt != nil)
    }

    @Test func theRepoFilterNarrowsAnOrgAndGoesWithIt() throws {
        func row(_ repo: String) -> PullRequestRow {
            PullRequestRow(
                repo: repo, number: 1, title: "t", head: "h", revision: "a", diff: .ready, detail: "d", status: nil
            )
        }
        var filter = PROrgFilter(selected: ["acme"])
        let lss = row("acme/LSS")
        let web = row("acme/Web")
        #expect(filter.shows(lss) && filter.shows(web), "no repo picked means all of them")
        filter.toggleRepo(lss.repo)
        #expect(filter.shows(lss) && !filter.shows(web))
        #expect(PROrgFilter(rawValue: filter.rawValue) == filter)
        filter.toggle("acme")
        #expect(filter.repos.isEmpty, "an org going takes its repos with it")
        let saved = try #require(PROrgFilter(rawValue: "acme,jai"))
        #expect(saved.selected == ["acme", "jai"] && saved.repos.isEmpty, "a value from before repos still reads")
    }

    @Test func aPageHoldsItsOwnRows() {
        func row(_ list: String) -> PullRequestRow {
            PullRequestRow(
                repo: "o/r", number: 1, title: "t", head: "h", revision: "a", diff: .ready, detail: "d",
                status: PullRequestRow.Status(
                    list: list, author: "a", checks: "passing", review: "none", merge: "clean", jaiReview: nil,
                    jaiReviewedAt: nil
                )
            )
        }
        #expect(PRListPage.review.holds(row("review")) && PRListPage.review.holds(row("reviewed")))
        #expect(PRListPage.mine.holds(row("mine")) && !PRListPage.mine.holds(row("review")))
    }

    @Test func anAnswerReadsAtOnceAndGoesWhenTheWorkerCatchesUp() {
        func status(_ list: String) -> PullRequestRow.Status {
            PullRequestRow.Status(
                list: list, author: "ann", checks: "passing", review: "required", merge: "clean", jaiReview: nil,
                jaiReviewedAt: nil
            )
        }
        func row(_ list: String, head: String = "h") -> PullRequestRow {
            PullRequestRow(
                repo: "o/r", number: 1, title: "t", head: head, revision: "a", diff: .ready, detail: "d",
                status: status(list)
            )
        }
        let answer = PRLocalAnswer(review: "commented", sentAt: "2026-11-02T01:00:00Z", head: "h")
        let read = row("review").answered(answer)
        #expect(read.isAnswered)
        #expect(!read.isReviewRequest)
        #expect(read.listPullRequest.jaiReview == .commented)
        #expect(read.listPullRequest.isDecidedByJai(since: .now))
        #expect(!row("mine").answered(answer).isAnswered, "Jai's own PR isn't a review he was asked for")
        #expect(answer.isNeeded(by: row("review")), "a plain comment never changes the Worker's list")
        #expect(!answer.isNeeded(by: row("reviewed")))
        #expect(!answer.isNeeded(by: row("review", head: "new")))
        #expect(!answer.isNeeded(by: nil))
    }

    @Test func aNewPRStaysHiddenUntilItsFilesAreHere() {
        let shown = PRMirror.publishable([row(1, revision: "a")], previous: []) { _ in false }
        #expect(shown.isEmpty)
    }

    @Test func anUpdatedPRKeepsItsOldVersionUntilTheNewOneLands() {
        let old = row(1, revision: "old")
        let new = row(1, revision: "new")
        #expect(PRMirror.publishable([new], previous: [old]) { $0.revision == "old" } == [old])
        #expect(PRMirror.publishable([new], previous: [old]) { $0.revision == "new" } == [new])
    }

    @Test func aPROffTheListLeavesAndTheWorkersOrderHolds() {
        let shown = PRMirror.publishable([row(2, revision: "a"), row(1, revision: "a")], previous: [
            row(1, revision: "a"), row(3, revision: "a"),
        ]) { _ in true }
        #expect(shown.map(\.number) == [2, 1])
    }

    @Test func aPullRequestLinkParsesAndOtherLinksDoNot() throws {
        let link = try #require(URL(string: "https://github.com/acme/web-app/pull/6952/files"))
        #expect(PullRequestRef(url: link) == PullRequestRef(repo: "acme/web-app", number: 6952))
        #expect(PullRequestRef(url: try #require(URL(string: "https://github.com/jai/skills/issues/4"))) == nil)
        #expect(PullRequestRef(url: try #require(URL(string: "https://linear.app/a/issue/ABC-1"))) == nil)
    }

    @Test func githubMarkdownLosesWhatOnlyAWebPageDrawsAndKeepsImagesAndFolds() {
        let source = """
        <!-- template -->
        [![Gate](https://x/badge.png 'Gate')](https://x/report)
        ![shot](https://x/a.png)
        <relative-time datetime="2026-10-31">Oct 31</relative-time>
        <details><summary>More</summary>
        - [x] done
        - [ ] open
        </details>
        """
        #expect(PRMarkdown.clean(source) == """
        [Gate](https://x/report)
        ![shot](https://x/a.png)
        Oct 31
        <details><summary>More</summary>
        - ☑︎ done
        - ☐ open
        </details>
        """)
    }

    @Test func aBoxLeavingReadsEmptyInsteadOfCrashingAndIsNotReopenedByAWrite() {
        var value: String? = "words"
        let open = Binding(get: { value }, set: { value = $0 }).whileOpen
        open.wrappedValue = "more"
        #expect(value == "more")
        value = nil
        #expect(open.wrappedValue.isEmpty)
        open.wrappedValue = "late"
        #expect(value == nil)
    }

    private func detail(checks: String, policy: String = "null") throws -> PullRequestDetail {
        try PullRequestDetail.decode(Data("""
        {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
        "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"BLOCKED","labels":[],"checks":[\(checks)],
        "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null,"policy":\(policy)}
        """.utf8))
    }

    /// `github-infrastructure#636`'s shape: PolicyBot the only required check, on top of the checks nobody requires.
    @Test func policyBotIsAmongTheChecksAndCountsAsRequired() throws {
        let optional = """
        {"name":"validate","state":"skipped","url":"v","required":false},
        {"name":"opt-in","state":"success","url":"o","required":false},
        {"name":"lint","state":"failure","url":"l","required":false}
        """
        let policy = #"{"state":"pending","description":null,"url":"p","required":true}"#
        let shown = try detail(checks: optional, policy: policy)
        #expect(shown.listedChecks.map(\.name) == ["PolicyBot", "lint", "opt-in", "validate"])
        #expect(shown.listedChecks.first?.url == "p")
        #expect(shown.checksSummary == "0/1 required checks pass")

        let notRequired = #"{"state":"approved","description":null,"url":"p","required":false}"#
        #expect(try detail(checks: optional, policy: notRequired).checksSummary == "No required checks")
        #expect(try detail(checks: "").checksSummary == "No required checks")
    }

    @Test func requiredChecksComeFirstAndTheCountIsWhatPasses() throws {
        let checks = """
        {"name":"z-build","state":"success","url":null,"required":true},
        {"name":"a-build","state":"success","url":null,"required":true},
        {"name":"unit","state":"failure","url":null,"required":true},
        {"name":"lint","state":"failure","url":null,"required":false}
        """
        let shown = try detail(checks: checks)
        #expect(shown.listedChecks.map(\.name) == ["unit", "a-build", "z-build", "lint"])
        #expect(shown.checksSummary == "2/3 required checks pass")
    }

    @Test func aDetailSavedBeforeRequiredCountsEveryCheck() throws {
        let saved = try detail(checks: #"{"name":"unit","state":"success","url":null}"#)
        #expect(saved.checksSummary == "1/1 checks pass")
    }

    @Test func aCommentReviewWithNoWordsStaysOutOfTheConversation() throws {
        let json = """
        {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
        "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
        "comments":{"nodes":[{"id":"c","author":null,"body":"hi","createdAt":"2026-10-31T01:00:00Z"}]},
        "reviews":{"nodes":[
          {"id":"silent","author":null,"state":"COMMENTED","body":"","submittedAt":"2026-10-31T02:00:00Z"},
          {"id":"ok","author":null,"state":"APPROVED","body":"","submittedAt":"2026-10-31T00:00:00Z"}]},
        "reviewThreads":{"nodes":[]},"title":null}
        """
        let detail = try PullRequestDetail.decode(Data(json.utf8))
        #expect(detail.conversation.map(\.id) == ["ok", "c"])
    }

    @Test func aRowIsDrawnAsAListsOpenPullRequest() {
        let status = PullRequestRow.Status(
            list: "review", author: "ann", checks: "failing", review: "approved", merge: "conflicting",
            jaiReview: nil, jaiReviewedAt: nil
        )
        let row = PullRequestRow(
            repo: "o/r", number: 1, title: "t", head: "h", revision: "r", diff: .ready, detail: "d", status: status
        )
        #expect(row.isReviewRequest)
        let pullRequest = row.listPullRequest
        #expect(pullRequest.listState == .open)
        #expect(pullRequest.author == "ann")
        #expect(pullRequest.url == "https://github.com/o/r/pull/1")
        #expect(pullRequest.status.signalMarks.map(\.text) == ["Checks fail", "Approved", "Conflicts"])
    }

    @Test func aRowFromBeforeStatusesIsOpenWithNoSignals() {
        let pullRequest = row(1, revision: "a").listPullRequest
        #expect(pullRequest.listState == .open)
        #expect(pullRequest.status.signalMarks.isEmpty)
    }

    @Test func aLineCommentCarriesExactlyWhatGitHubNeeds() throws {
        let write = PRWrite.line(path: "f", line: 3, side: .left, body: "b", commit: "c")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: AnyHashable]
        #expect(encoded == ["kind": "line", "path": "f", "line": 3, "side": "LEFT", "body": "b", "commit": "c"])
    }

    @Test func aRemovedLineTakesItsCommentOnTheOldSideAndAHeaderTakesNone() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -7 +7 @@\n-old\n".utf8))
        guard case let .line(path, line, side) = PRComposerTarget(document, line: document.lines[4]) else {
            Issue.record("a removed line takes a comment")
            return
        }
        #expect((path, line, side) == ("f", 7, .left))
        #expect(PRComposerTarget(document, line: document.lines[3]) == nil)
    }

    @MainActor
    @Test func twoOpensOfOnePRAreTwoSessionsAndEachKeepsItsOwnPR() {
        let model = PRsModel(client: PRViewerClient(access: .offline, transport: .background))
        let first = model.session(for: PullRequestRef(repo: "o/a", number: 1))
        let again = model.session(for: PullRequestRef(repo: "o/a", number: 1))
        let other = model.session(for: PullRequestRef(repo: "o/b", number: 2))
        #expect(first != again)
        #expect(first.label == "o/a#1" && other.label == "o/b#2")
        #expect(first.title == "o/a#1")
    }

    @Test func aPendingCommentSitsUnderItsLineOnItsSide() {
        let document = DiffDocument(data: Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -5 +5 @@\n-old\n+new\n".utf8))
        let draft = { (line: Int, side: PRDiffSide) in
            PRDraftComment(id: UUID(), path: "f", line: line, side: side, body: "b")
        }
        let rows = DiffRows(document: document, threads: [], drafts: [draft(5, .right), draft(5, .left)])
        #expect(rows.files[0].rows == [.line(3), .line(4), .draft(1), .line(5), .draft(0)])
    }
}
