import Foundation
@testable import PRKit
import Testing

@MainActor
struct PRAskPolicyTests {
    private let question = PRAskQuestion(question: "Is it tested?", head: String(repeating: "a", count: 40), anchor: nil)
    private let chat = PRAskChat(
        messages: [.init(id: "m1", role: "you", text: "Is it tested?", anchor: nil)],
        isWorking: true, activity: nil, problem: nil, costCents: nil
    )

    @Test func aQuestionHeldOfflineWaitsForTheNetwork() {
        #expect(PRAskSend.after(.success(.queued), of: question, isOnline: false) == .waitingForNetwork(question))
        // The network comes back while the outbox still holds it: on its way again.
        #expect(PRAskSend.waitingForNetwork(question).following(isQueued: true, isOnline: true) == .sending(question))
        #expect(PRAskSend.sending(question).following(isQueued: true, isOnline: false) == .waitingForNetwork(question))
    }

    @Test func aChatThatKeepsFailingIsReadLessOften() {
        #expect(PRSession.askPollWait(afterFailures: 0) == .seconds(2))
        #expect(PRSession.askPollWait(afterFailures: 1) == .seconds(4))
        #expect(PRSession.askPollWait(afterFailures: 3) == .seconds(16))
        #expect(PRSession.askPollWait(afterFailures: 4) == .seconds(30))
        #expect(PRSession.askPollWait(afterFailures: 400) == .seconds(30))
    }

    @Test func aQuestionTheWorkerCouldNotHandOverCanBeSentAgain() {
        let failed = PRAskChat(
            messages: [.init(id: "queued:ref-1", role: "you", text: "Is it tested?", anchor: nil)],
            isWorking: false, activity: nil, problem: "The AI couldn't be reached. Try again.", costCents: nil
        )
        #expect(failed.unsentQuestion?.text == "Is it tested?")
        #expect(chat.unsentQuestion == nil)
    }

    @Test func aTurnThatFailedCanBeSentAgainAboutTheSameLine() {
        let failed = PRAskChat(
            messages: [
                .init(id: "3f2a9c1e-77", role: "you", text: "Why?", anchor: "src/api/retry.ts:42", side: "LEFT"),
            ],
            isWorking: false, activity: nil,
            problem: "GitHub 403: GitHub's rate limit for your account is used up, resets 02:59 UTC · turn 3f2a9c1e",
            costCents: nil
        )
        #expect(failed.unsentQuestion?.text == "Why?")
        let anchor = PRAskQuestion.Anchor(path: "src/api/retry.ts", line: 42, side: "LEFT")
        #expect(failed.unsentQuestion?.askedAbout == anchor, "the old side stays the old side")
        let answered = PRAskChat(
            messages: failed.messages + [.init(id: "a1", role: "agent", text: "Because.", anchor: nil)],
            isWorking: false, activity: nil, problem: "x", costCents: nil
        )
        #expect(answered.unsentQuestion == nil, "an answered question is not a failed one")
    }
}
