import Foundation
import PRKitCore
import Testing

struct PRListReviewTests {
    private let now = Date(timeIntervalSince1970: 1_793_163_660)
    private let format = ThreadTimeFormat(timeZone: TimeZone(identifier: "Asia/Bangkok")!, locale: Locale(identifier: "en_GB"))
    private static let approved = #""jai_review":"approved","jai_reviewed_at":"2026-10-28T05:01:10Z","jai_review_requested":false"#

    private func pullRequest(_ review: String = "") throws -> PRListPullRequest {
        let json = #"""
        {"repo":"Acme/Web","number":7,"url":"https://github.com/Acme/Web/pull/7",
         "state":"draft","checks":"passing","merge":"blocked","review":"approved","author":"octocat","found":true
        """# + (review.isEmpty ? "}" : ",\(review)}")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PRListPullRequest.self, from: Data(json.utf8))
    }

    @Test func decodesJaisReviewAndReadsAnUnknownOrAbsentOneAsNone() throws {
        let reviewed = try pullRequest(Self.approved)
        #expect(reviewed.jaiReview == .approved && reviewed.jaiReviewRequested == false)
        #expect(reviewed.jaiReviewedAt == Date(timeIntervalSince1970: 1_793_163_670))
        #expect(reviewed.key == "acme/web#7")
        let newer = try pullRequest(#""jai_review":"lgtm","jai_review_requested":true"#)
        #expect(newer.jaiReview == nil && newer.jaiReviewRequested == true)
        let older = try pullRequest()
        #expect(older.jaiReview == nil && older.jaiReviewedAt == nil && older.jaiReviewRequested == nil)
    }

    @Test func theMarkSaysHisReviewThenThatHeWasAskedAgainElseThatHeOpenedIt() throws {
        var pullRequest = try pullRequest(Self.approved)
        let later = now.addingTimeInterval(3 * 60)
        let mark = { pullRequest.jaiMark(openedAt: now, now: later, format: format) }
        #expect(mark() == PrJaiMark(kind: .approved, text: "You approved · 2m ago"))
        let before = now.addingTimeInterval(-86400)
        let after = now.addingTimeInterval(86400)
        #expect(pullRequest.isDecidedByJai(since: before))
        #expect(!pullRequest.isDecidedByJai(since: after))
        pullRequest.jaiReview = .commented
        #expect(!pullRequest.isDecidedByJai(since: before))
        pullRequest.jaiReviewRequested = true
        #expect(mark() == PrJaiMark(kind: .askedAgain, text: "Asked again · you commented · 2m ago"))
        #expect(!pullRequest.isDecidedByJai(since: before))
        pullRequest.jaiReview = .changesRequested
        pullRequest.jaiReviewRequested = false
        #expect(mark() == PrJaiMark(kind: .blocking, text: "You're blocking · you requested changes · 2m ago"))
        pullRequest.jaiReviewRequested = true
        #expect(mark()?.kind == .blocking)
        pullRequest.status.state = .merged
        #expect(mark()?.text == "Asked again · you requested changes · 2m ago")
        pullRequest.status.state = .open
        pullRequest.jaiReviewRequested = false
        pullRequest.jaiReview = .pending
        pullRequest.jaiReviewedAt = nil
        #expect(mark() == PrJaiMark(kind: .draft, text: "Your review is a draft"))
        #expect(!pullRequest.isDecidedByJai(since: before))
        pullRequest.jaiReview = nil
        #expect(mark() == PrJaiMark(kind: .opened, text: "Opened 3m ago"))
        #expect(pullRequest.jaiMark(openedAt: nil, now: later, format: format) == nil)
    }

    @Test func anItemFadesOnlyOnceJaiHasReviewedEveryPR() throws {
        let sent = now.addingTimeInterval(-86400)
        var item = try PRListItem(ticket: nil, pullRequests: [pullRequest(Self.approved)], title: nil, note: nil)
        #expect(item.isDecidedByJai(since: sent))
        try item.pullRequests.append(pullRequest())
        #expect(!item.isDecidedByJai(since: sent))
        item.pullRequests = []
        #expect(!item.isDecidedByJai(since: sent))
    }
}
