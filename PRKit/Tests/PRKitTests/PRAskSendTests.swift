import Foundation
import Testing
@testable import PRKit

/// A question to the PR's AI between its send and the chat having it: slow, offline, failed and answered.
@MainActor
struct PRAskSendTests {
    /// An outbox that holds what it is given until the test says it went.
    @MainActor
    final class Outbox: PRKitOutbox {
        var isHolding = true
        private(set) var ids: [String] = []

        func enqueue(_ job: PROutboxJob) async throws -> String {
            guard case .question = job else {
                return "write"
            }
            ids.append("ask-\(ids.count + 1)")
            return ids[ids.count - 1]
        }

        func isQueued(_ kind: PROutboxJob.Kind, about ref: PullRequestRef) -> Bool {
            kind == .question && isHolding && !ids.isEmpty
        }
    }

    @MainActor
    final class Host: PRKitHost {
        let access = PRViewerAccess.offline
        let configuration = PRKitConfiguration.everything
        let held = Outbox()
        var outbox: (any PRKitOutbox)? { held }
        let apnsEnvironment = "sandbox"
        let samples: PRSampleSet? = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
        let launchOptions = PRKitLaunchOptions.none

        func isInForeground() async -> Bool { false }
        func log(_ line: String) {}
        func receive(_ event: PRKitEvent) {}
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private let question = PRAskQuestion(question: "Is it tested?", head: String(repeating: "a", count: 40), anchor: nil)
    private let chat = PRAskChat(
        messages: [.init(id: "m1", role: "you", text: "Is it tested?", anchor: nil)],
        isWorking: true, activity: nil, problem: nil, costCents: nil
    )

    private func kit(wait: Duration = .milliseconds(100)) -> (PRKitController, Host) {
        let host = Host()
        let kit = PRKitController(host: host)
        kit.model.answerWait = wait
        return (kit, host)
    }

    @Test func aSlowAnswerOnlineIsStillSendingNotAnError() async throws {
        let (kit, _) = kit()
        let outcome = try await kit.model.ask(question, about: ref)
        #expect(outcome == .queued)
        #expect(PRAskSend.after(.success(outcome), of: question, isOnline: true) == .sending(question))
    }

    @Test func aQuestionHeldOfflineWaitsForTheNetwork() {
        #expect(PRAskSend.after(.success(.queued), of: question, isOnline: false) == .waitingForNetwork(question))
        // The network comes back while the outbox still holds it: on its way again.
        #expect(PRAskSend.waitingForNetwork(question).following(isQueued: true, isOnline: true) == .sending(question))
        #expect(PRAskSend.sending(question).following(isQueued: true, isOnline: false) == .waitingForNetwork(question))
    }

    @Test func theWorkersAnswerEndsTheSend() async throws {
        let (kit, host) = kit(wait: .seconds(5))
        let asked = Task { try await kit.model.ask(question, about: ref) }
        while host.held.ids.isEmpty {
            await Task.yield()
        }
        kit.outboxAnswered(id: "ask-1", data: Data("""
            {"messages":[{"id":"m1","role":"you","text":"Is it tested?","anchor":null}],"isWorking":true,\
            "activity":null,"problem":null,"costCents":null}
            """.utf8))
        let outcome = try await asked.value
        #expect(outcome == .answered(chat))
        #expect(PRAskSend.after(.success(outcome), of: question, isOnline: true) == .idle)
        // One the outbox let go after the wait is the Worker's now.
        #expect(PRAskSend.sending(question).following(isQueued: false, isOnline: true) == .idle)
    }

    @Test func aRefusalFailsWithItsReasonAndTryAgainHasTheQuestion() async {
        let (kit, host) = kit(wait: .seconds(5))
        let asked = Task { try await kit.model.ask(question, about: ref) }
        while host.held.ids.isEmpty {
            await Task.yield()
        }
        kit.outboxRefused(id: "ask-1", kind: .question, reason: "This chat reached its spending limit.")
        let outcome: Result<PRAskOutcome, any Error> = await asked.result
        let send = PRAskSend.after(outcome, of: question, isOnline: true)
        #expect(send == .failed(question, reason: "This chat reached its spending limit."))
        #expect(send.question == question && !send.isOnItsWay)
        // Following never clears a failure: only Try again does.
        #expect(send.following(isQueued: false, isOnline: true) == send)
    }

    @Test func followingAQueuedQuestionShowsNoError() async throws {
        let (kit, host) = kit()
        _ = try await kit.model.ask(question, about: ref)
        kit.model.isOnline = { false }
        let session = kit.model.session(for: ref)
        session.askSend = .sending(question)
        let following = Task { await session.followAsk() }
        while session.askSend == .sending(question) {
            await Task.yield()
        }
        #expect(session.askSend == .waitingForNetwork(question))
        #expect(session.askError == nil)
        host.held.isHolding = false
        await following.value
        #expect(session.askSend == .idle)
        #expect(session.askError == nil)
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

struct PRAskReadProblemTests {
    @Test func anUnreachableWorkerIsQuietAndARefusalIsNot() {
        let unreachable = PRAskReadProblem(URLError(.networkConnectionLost))
        #expect(unreachable == .unreachable && !unreachable.isFailure)
        #expect(!unreachable.words.contains("network connection was lost"))
        let refused = PRAskReadProblem(PRWorkerError.refused("Ask is not set up on this Worker."))
        #expect(refused == .failed("Ask is not set up on this Worker.") && refused.isFailure)
    }
}
