import DurableNetworking
import Foundation
@testable import PRKit
import Testing

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

        func isQueued(_ kind: PROutboxJob.Kind, about _: PullRequestRef) -> Bool {
            kind == .question && isHolding && !ids.isEmpty
        }
    }

    @MainActor
    final class Host: PRKitHost {
        let access = PRViewerAccess.offline
        let configuration = PRKitConfiguration.everything
        let held = Outbox()
        var outbox: (any PRKitOutbox)? {
            held
        }

        let apnsEnvironment = "sandbox"
        let samples: PRSampleSet? = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
        let launchOptions = PRKitLaunchOptions.none

        let transport: any HTTPTransport = URLSessionTransport.background
        func log(_: String) {}
        private(set) var events: [PRKitEvent] = []
        func receive(_ event: PRKitEvent) {
            events.append(event)
        }
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

    /// A PR on screen, so a question can name its head.
    private func loadedSession(_ kit: PRKitController) throws -> PRSession {
        let detail = try PullRequestDetail.decode(Data("""
        {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
        "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
        "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
        """.utf8))
        return PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: nil), tappedAt: 0, model: kit.model
        )
    }

    @Test func eachQuestionTellsTheHostWhatAskedItAndHowItWent() async throws {
        let (kit, host) = kit()
        let session = try loadedSession(kit)
        session.explainPR()
        while host.events.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.askDraft = "Is it tested?"
        await session.sendAsk()
        session.askAnchor = PRAskQuestion.Anchor(path: "a.swift", line: 3, side: "RIGHT", code: nil)
        session.askDraft = "Why this line?"
        await session.sendAsk()
        #expect(host.events == [
            .askSent(.explainPR, .queued), .askSent(.typed, .queued), .askSent(.typedLine, .queued),
        ])
    }

    @Test func aQuestionThatGotNoAnswerIsToldOnceHoweverOftenItIsRead() throws {
        let (kit, host) = kit()
        let session = try loadedSession(kit)
        let failed = { (id: String) in
            PRAskChat(
                messages: [.init(id: id, role: "you", text: "Is it tested?", anchor: nil)],
                isWorking: false, activity: nil, problem: "The AI couldn't be reached. Try again.", costCents: nil
            )
        }
        session.reportAnswerFailure(in: chat)
        session.reportAnswerFailure(in: failed("m1"))
        session.reportAnswerFailure(in: failed("m1"))
        session.reportAnswerFailure(in: failed("m2"))
        #expect(host.events == [.askAnswerFailed, .askAnswerFailed])
    }

    private func session(_ kit: PRKitController) -> PRSession {
        PRSession(ref: ref, title: nil, content: nil, tappedAt: 0, model: kit.model)
    }

    /// The 2026-11-10 bug bash: a question typed and not sent was gone after a visit to another PR.
    @Test func anUnsentQuestionIsStillThereWhenThePROpensAgain() {
        let (made, _) = kit()
        let first = session(made)
        first.openAsk()
        first.askDraft = "kiwi draft about retries"
        let other = PRSession(
            ref: PullRequestRef(repo: "acme/api", number: 8), title: nil, content: nil, tappedAt: 0, model: made.model
        )
        #expect(other.askDraft.isEmpty)
        #expect(session(made).askDraft == "kiwi draft about retries")
    }

    /// The bug bash again: words written about the whole PR showed as the question about a line opened next.
    @Test func wordsAboutThePRAreNotAQuestionAboutALine() {
        let (made, _) = kit()
        let asking = session(made)
        asking.openAsk()
        asking.askDraft = "whole PR draft"
        asking.openAsk(about: PRAskQuestion.Anchor(path: "src/cart/store.ts", line: 12, side: "RIGHT"))
        #expect(asking.askDraft.isEmpty)
        asking.askDraft = "why this line?"
        // Dropping the line keeps what he wrote about it, as the question about the PR.
        asking.askAboutWholePR()
        #expect(asking.askAnchor == nil && asking.askDraft == "why this line?")
    }

    @Test func aFailedQuestionsWordsGoBackToWhatItWasAbout() {
        let (made, _) = kit()
        let asking = session(made)
        let anchor = PRAskQuestion.Anchor(path: "a.swift", line: 3, side: "RIGHT")
        asking.redraft("Is this safe?", about: anchor)
        #expect(asking.askAnchor == anchor && asking.askDraft == "Is this safe?")
        asking.askAboutWholePR()
        asking.askDraft = ""
        #expect(made.model.askDrafts.isEmpty, "an emptied box keeps nothing")
    }
}
