import Foundation
import PRKit
import PRKitCore
import Testing

struct PRListDisplayTests {
    private typealias Fixture = PrListsFixture
    private let format = Fixture.format
    private let now = Fixture.now

    @Test func aTicketHeadlineIsItsKeyAndTitleElseTheItemsTitleElseTheKey() {
        #expect(Fixture.item(Fixture.ticket()).headline == "ENG-7 Accept UK mobile numbers at phone sign-in")
        #expect(Fixture.item(Fixture.ticket(title: "ENG-7: phone sign-in")).headline == "ENG-7: phone sign-in")
        let pending = Fixture.ticket("ENG-8", found: nil)
        #expect(Fixture.item(pending, title: "Retry photo uploads").headline == "ENG-8 Retry photo uploads")
        #expect(Fixture.item(pending, [Fixture.pullRequest()]).headline == "ENG-8")
        #expect(Fixture.item(Fixture.ticket("ENG-9", found: false), title: "Gone").headline == "ENG-9 Gone")
    }

    @Test func aTicketThatIsAButtonSaysWhatItIsThenWhatLinearHasForIt() {
        #expect(Fixture.ticket().spokenLine
            == "Linear ticket ENG-7, Accept UK mobile numbers at phone sign-in, In Review")
        var owned = Fixture.ticket()
        owned.assignee = "Alex Doe"
        #expect(owned.spokenLine
            == "Linear ticket ENG-7, Accept UK mobile numbers at phone sign-in, assigned to Alex Doe, In Review")
        #expect(Fixture.ticket("ENG-8", found: nil).spokenLine == "Linear ticket ENG-8")
        #expect(Fixture.ticket("ENG-9", found: false).spokenLine == "Linear ticket ENG-9, Not found")
    }

    @Test func withoutATicketTheHeadlineIsTheFirstPRsTitleElseTheItemsTitleElseTheRef() {
        let first = Fixture.pullRequest(title: "fix: Use full-page redirects for sign-in")
        let second = Fixture.pullRequest("acme/tools", 58, title: "Lists")
        #expect(Fixture.item(nil, [first, second], title: "Agent's words").headline
            == "fix: Use full-page redirects for sign-in")
        let pending = Fixture.pullRequest("acme/sms-sender", 341, found: nil)
        #expect(Fixture.item(nil, [pending], title: "Upgrade PHP").headline == "Upgrade PHP")
        #expect(Fixture.item(nil, [pending, second]).headline == "acme/sms-sender#341")
        #expect(Fixture.item(nil, [Fixture.pullRequest(found: false)]).headline == "acme/web-app#6798")
    }

    @Test func aTicketsStateSaysWhetherItIsResolvedFoundOrMissing() {
        #expect(Fixture.ticket().stateText == "In Review")
        #expect(Fixture.ticket(found: nil).stateText == "Resolving…")
        #expect(Fixture.ticket(found: false).stateText == "Not found")
        #expect(Fixture.ticket(state: nil).stateText == "Unknown")
    }

    @Test func aPullRequestsMetaLineIsWhereWhoAndHowLongAgo() {
        let meta = { (pullRequest: PRListPullRequest, showsAuthor: Bool) in
            PRListItem(ticket: nil, pullRequests: [pullRequest], title: nil, note: nil)
                .metaLine(of: pullRequest, now: now, format: format, showsAuthor: showsAuthor)
        }
        let mona = Fixture.pullRequest(openedDaysAgo: 0.5, author: "octocat", authorName: "Mona Lisa")
        #expect(meta(mona, true) == "Mona · web-app#6798 · 12h")
        #expect(meta(mona, false) == "web-app#6798 · 12h")
        #expect(meta(Fixture.pullRequest("acme/integrations", 690, openedDaysAgo: 3, author: "alex"), true)
            == "alex · integrations#690 · 3d")
        #expect(meta(Fixture.pullRequest(openedDaysAgo: nil), true) == "web-app#6798")
    }

    @Test func aPullRequestsStateIsGitHubsOwnOrThatTheHubHasNotGotItYet() {
        #expect(Fixture.pullRequest().listState == .open)
        #expect(Fixture.pullRequest(state: .draft).listState == .draft)
        #expect(Fixture.pullRequest(state: .merged, merge: nil).listState == .merged)
        #expect(Fixture.pullRequest(state: .closed, merge: nil).listState == .closed)
        #expect(Fixture.pullRequest(found: nil).listState == .resolving)
        #expect(Fixture.pullRequest(found: false).listState == .notFound)
    }

    @Test func theMetaLineLeavesOutARefThatIsAlreadyTheTitle() {
        let unnamed = Fixture.pullRequest(title: nil, found: false)
        let item = PRListItem(ticket: nil, pullRequests: [unnamed], title: nil, note: nil)
        #expect(item.title(of: unnamed) == unnamed.ref)
        #expect(item.metaLine(of: unnamed, now: now, format: format, showsAuthor: true).isEmpty)
    }

    @Test func aThreadsPullRequestKeepsItsAuthorAsAList() {
        var pullRequest = Fixture.pullRequest().status
        pullRequest.author = "octocat"
        pullRequest.authorName = "Mona Lisa"
        #expect(pullRequest.listPullRequest.authorShortName == "Mona")
        #expect(pullRequest.listPullRequest.avatarURL?.absoluteString == "https://github.com/octocat.png?size=96")
    }

    @Test func anAuthorsPictureIsGitHubsForTheirLoginAndOnlyForALoginGitHubCouldHave() {
        #expect(Fixture.pullRequest(author: "alex").avatarURL?.absoluteString == "https://github.com/alex.png?size=96")
        #expect(Fixture.pullRequest(author: "octo-cat").avatarURL != nil)
        #expect(Fixture.pullRequest().avatarURL == nil)
        #expect(Fixture.pullRequest(author: "../x").avatarURL == nil)
        #expect(Fixture.pullRequest(author: "a b").avatarURL == nil)
        #expect(Fixture.pullRequest(authorName: "Alex Doe").authorShortName == "Alex")
    }

    @Test func anItemShowsItsTicketAndPullRequest() {
        let item = Fixture.item(Fixture.ticket(), [Fixture.pullRequest(
            title: "Accept UK mobile numbers at phone sign-in", state: .draft, merge: .blocked,
            review: .approved, openedDaysAgo: 3, author: "octocat", authorName: "Mona Lisa"
        )])
        #expect(item.headline == "ENG-7 Accept UK mobile numbers at phone sign-in")
        #expect(item.ticket?.stateText == "In Review")
        #expect(item.pullRequests.map { item.metaLine(of: $0, now: now, format: format, showsAuthor: true) }
            == ["Mona · web-app#6798 · 3d"])
        #expect(item.pullRequests.first?.status.statusMarks.map(\.text) == ["Draft", "Checks pass", "Approved"])
        #expect(item.pullRequests.first?.avatarURL?.absoluteString == "https://github.com/octocat.png?size=96")
    }

    @Test func aListsSignalsAreTheMarksWithoutTheState() {
        let signals = { (pullRequest: PRListPullRequest) in pullRequest.status.signalMarks.map(\.text) }
        #expect(signals(Fixture.pullRequest(state: .merged, merge: nil)).isEmpty)
        #expect(signals(Fixture.pullRequest(state: .closed, merge: nil)).isEmpty)
        #expect(signals(Fixture.pullRequest(state: .draft, merge: .conflicting, review: .noReview))
            == ["Checks pass", "Conflicts"])
        #expect(signals(Fixture.pullRequest(state: .draft, merge: .behind, review: .noReview)) == ["Checks pass"])
        #expect(signals(Fixture.pullRequest(merge: .blocked)) == ["Checks pass", "Needs review"])
    }

    @Test func aLinearColourIsReadOnlyFromItsHexForm() {
        #expect(LinearPalette.parsed("#5e6ad2") == 0x5E6AD2)
        #expect(LinearPalette.parsed("5e6ad2") == nil)
        #expect(LinearPalette.parsed("#zzzzzz") == nil)
    }

    @Test func aPullRequestsMarksSayWhereItStandsWithBlockedOnlyWhereNothingElseSaysWhy() {
        let marks = { (pullRequest: PRListPullRequest) in pullRequest.status.statusMarks.map(\.text) }
        #expect(marks(Fixture.pullRequest(state: .merged, merge: nil)) == ["Merged"])
        #expect(marks(Fixture.pullRequest(state: .closed, merge: nil)) == ["Closed"])
        #expect(marks(Fixture.pullRequest(checks: .failing, merge: .behind))
            == ["Checks fail", "Needs review", "Out of date"])
        #expect(marks(Fixture.pullRequest(state: .draft, checks: .pending, merge: .blocked, review: .noReview))
            == ["Draft", "Checks running"])
        #expect(marks(Fixture.pullRequest(merge: .blocked, review: .approved))
            == ["Checks pass", "Approved", "Blocked"])
        #expect(marks(Fixture.pullRequest(merge: .blocked)) == ["Checks pass", "Needs review"])
        #expect(marks(Fixture.pullRequest(checks: .pending, merge: .unstable, review: .approved))
            == ["Checks running", "Approved"])
        #expect(marks(Fixture.pullRequest(checks: .noChecks, merge: .clean, review: .approved))
            == ["Approved", "Ready to merge"])
        #expect(marks(Fixture.pullRequest(merge: .conflicting, review: .changesRequested))
            == ["Checks pass", "Changes requested", "Conflicts"])
        #expect(marks(Fixture.pullRequest(found: nil)).isEmpty)
    }
}

private enum PrListsFixture {
    static let now = Date(timeIntervalSince1970: 1_793_163_660)
    static let format = ThreadTimeFormat(timeZone: TimeZone(identifier: "Asia/Bangkok")!, locale: Locale(identifier: "en_GB"))
    static func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    /// Unless `found` is `true`, every field after the key is `nil` but a URL, as the contract has it.
    static func ticket(
        _ key: String = "ENG-7", title: String? = "Accept UK mobile numbers at phone sign-in",
        state: String? = "In Review", found: Bool? = true, resolvedMinutesAgo: Double = 1
    ) -> PRListTicket {
        let resolved = found == true
        return PRListTicket(
            key: key, url: "https://linear.app/acme/issue/\(key)", title: resolved ? title : nil,
            state: resolved ? state : nil, stateType: resolved ? "started" : nil, found: found,
            resolvedAt: found == nil ? nil : minutesAgo(resolvedMinutesAgo)
        )
    }

    static func pullRequest(
        _ repo: String = "acme/web-app", _ number: Int = 6798, title: String? = "A PR",
        state: PullRequestStatus.State? = .open, checks: PullRequestStatus.Checks? = .passing,
        merge: PullRequestStatus.Merge? = .clean, review: PullRequestStatus.Review? = .required,
        openedDaysAgo: Double? = 1, found: Bool? = true, resolvedMinutesAgo: Double = 1, author: String? = nil,
        authorName: String? = nil
    ) -> PRListPullRequest {
        let resolved = found == true
        let status = PullRequestStatus(
            repo: repo, number: number, url: "https://github.com/\(repo)/pull/\(number)",
            title: resolved ? title : nil, state: resolved ? state : nil, checks: resolved ? checks : nil,
            merge: resolved ? merge : nil, review: resolved ? review : nil
        )
        return PRListPullRequest(
            status: status, createdAt: resolved ? openedDaysAgo.map { minutesAgo($0 * 1440) } : nil,
            author: resolved ? author : nil, authorName: resolved ? authorName : nil, found: found,
            resolvedAt: found == nil ? nil : minutesAgo(resolvedMinutesAgo)
        )
    }

    static func item(
        _ ticket: PRListTicket? = nil, _ pullRequests: [PRListPullRequest] = [], title: String? = nil
    ) -> PRListItem {
        PRListItem(ticket: ticket, pullRequests: pullRequests, title: title, note: nil)
    }
}
