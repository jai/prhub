import Foundation
@testable import PRKit
import PRKitCore
import Testing

/// How an action went, read from its error alone: a closed set, never the error's words.
struct PRActionOutcomeTests {
    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, PRActionFailure.offline), (.cannotFindHost, .offline),
        (.timedOut, .timeout), (.secureConnectionFailed, .network), (.badServerResponse, .network),
    ])
    func aConnectionsFailureSaysWhich(_ code: URLError.Code, _ expected: PRActionFailure) {
        #expect(PRActionFailure(URLError(code)) == expected)
    }

    @Test(arguments: [
        (PRWorkerError.signedOut, PRActionFailure.signedOut), (.notFound, .notFound), (.unreachable(.ask), .notFound),
        (.tooLarge, .tooLarge), (.unreadableRequest, .badRequest), (.limited, .rateLimited),
        (.unavailable, .unavailable), (.unexpected(status: 418), .unexpected), (.notPaired, .local),
        (.refused("Base branch was modified for acme/secret"), .refused),
    ])
    func theWorkersAnswerSaysWhichWithoutItsWords(_ error: PRWorkerError, _ expected: PRActionFailure) {
        #expect(PRActionFailure(error) == expected)
    }

    @Test func thePhonesOwnRefusalsAreLocal() {
        #expect(PRActionFailure(PRLocalRefusal.sampleWrite) == .local)
        #expect(PRActionFailure(PRLocalRefusal.notLoaded) == .local)
        #expect(PRActionFailure(SamplesPostNothing()) == .local)
        #expect(PRActionFailure(PRAIHeadMoved()) == .moved)
        #expect(PRActionFailure(CocoaError(.fileNoSuchFile)) == .other)
    }

    @Test func aCancelledActionIsNoFailure() {
        #expect(PRActionFailure(CancellationError()) == nil)
        #expect(PRActionFailure(URLError(.cancelled)) == nil)
        #expect(PRActionOutcome(error: CancellationError()) == nil)
        #expect(PRActionOutcome(error: URLError(.timedOut)) == .failed(.timeout))
    }

    @Test func eachWriteIsItsKind() {
        let review = { (event: PRReviewEvent) in PRWrite.review(event, body: "", commit: "c", comments: []) }
        #expect(PRWriteKind(review(.approve)) == .approve)
        #expect(PRWriteKind(review(.requestChanges)) == .requestChanges)
        #expect(PRWriteKind(review(.comment)) == .review)
        #expect(PRWriteKind(.resolve(thread: "t", resolved: false)) == .reopen)
        #expect(PRWriteKind(.viewed(pullRequest: "p", path: "a.swift", viewed: true)) == .viewed)
        #expect(PRWriteKind(.editBody("New words", base: nil)) == .editBody)
        #expect(PRWriteKind(.merge(method: "squash", commit: "c")) == .merge)
    }

    @Test func anAIAnswerIsItsKindByItsRoute() {
        #expect(PRAIKind(route: "key-lines") == .keyLines)
        #expect(PRAIKind(route: "rewrite") == .rewrite)
        #expect(PRAIKind(route: "summary") == nil, "a route the host isn't told of")
    }

    @Test func aDecodingFailureIsUnreadable() {
        #expect(PRActionFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == .unreadable)
    }
}
