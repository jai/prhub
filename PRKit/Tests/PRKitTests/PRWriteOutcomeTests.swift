import Foundation
import PRKitDesign
import SwiftUI
import Testing
@testable import PRKit

/// The Worker's answers read once, at the client, and each kind of queued job in its own words.
struct PRWorkerErrorTests {
    @Test(arguments: [
        (401, PRWorkerError.signedOut), (404, .notFound), (410, .notFound), (406, .tooLarge), (413, .tooLarge),
        (400, .unreadableRequest), (422, .unreadableRequest), (429, .limited), (500, .unavailable),
        (503, .unavailable), (418, .unexpected(status: 418)),
    ])
    func eachStatusIsItsOwnCase(_ status: Int, _ expected: PRWorkerError) {
        #expect(PRWorkerError(status: status) == expected)
    }

    @Test(arguments: [401, 404, 406, 400, 429, 500, 418])
    func aMessageSaysWhatToDoAndNeverAStatus(_ status: Int) throws {
        let words = try #require(PRWorkerError(status: status).errorDescription)
        #expect(words.firstMatch(of: /\d{3}/) == nil)
        #expect(words.hasSuffix("."))
        #expect(!words.contains("PR viewer Worker answered"))
    }

    @Test func theWorkersWordsWinOverItsStatus() {
        let body = Data(#"{"error":"Pull request is locked"}"#.utf8)
        #expect(PRWorkerError(status: 422, body: body) == .refused("Pull request is locked", isPermanent: true))
        #expect(PRWorkerError(status: 502, body: body) == .refused("Pull request is locked"))
        let limit = Data(#"{"error":{"code":"limit_reached","message":"writes_per_minute reached"}}"#.utf8)
        #expect(PRWorkerError(status: 429, body: limit) == .limited)
    }

    @Test func onlyWhatCantChangeIsPermanent() {
        #expect(PRWorkerError.notFound.isPermanent && PRWorkerError.tooLarge.isPermanent)
        #expect(!PRWorkerError.unavailable.isPermanent && !PRWorkerError.limited.isPermanent)
        #expect(!PRWorkerError.refused("x").isPermanent)
    }
}

@MainActor
struct PRNoticeTests {
    @Test func aQueuedWriteWaitsInTheWaitingToneAndSaysWhere() {
        let sending = PRNotice.queued(noun: PRWrite.comment(body: "x").noun, .sending)
        #expect(sending.words == "Your comment is saved on this phone and on its way to GitHub.")
        #expect(sending.tone == .toneWaiting)
        let offline = PRNotice.queued(noun: PRWrite.review(.approve, body: "", commit: "c", comments: []).noun,
                                      .waitingForNetwork)
        #expect(offline.words == "Your review is saved on this phone. It goes to GitHub when you're back online.")
        #expect(!offline.words.lowercased().contains("error"))
    }

    @Test func onlyAFailureIsBad() {
        #expect(PRNotice.failed("Pull request is locked").tone == .toneBad)
        #expect(PRNotice.sampleOnly.tone == .secondary)
        #expect(PRNotice.rewroteWithoutTicket.tone == .secondary)
    }

    @Test func viewedMarksAndLeavingAReviewGoQuietly() {
        #expect(!PRWrite.viewed(pullRequest: "p", path: "f", viewed: true).saysWhenQueued)
        #expect(!PRWrite.removeRequest.saysWhenQueued)
        #expect(PRWrite.checkbox(index: 0, checked: true, task: nil).saysWhenQueued)
    }

    @Test func aLateRefusalNamesTheWriteAndQuotesHisWords() {
        let ref = PullRequestRef(repo: "acme/api", number: 7)
        #expect(PRWrite.reply(thread: "t", body: "Done").refusal(on: ref, reason: "Locked")
            == "GitHub refused your reply “Done” on acme/api#7: Locked")
        #expect(PRWrite.resolve(thread: "t", resolved: true).refusal(on: ref, reason: "Locked")
            == "GitHub refused resolving the thread on acme/api#7: Locked")
        #expect(PRWrite.review(.approve, body: "", commit: "c", comments: []).refusal(on: ref, reason: "Stale")
            == "GitHub refused your review on acme/api#7: Stale")
    }
}
