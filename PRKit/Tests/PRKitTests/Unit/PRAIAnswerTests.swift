import Foundation
@testable import PRKit
import PRKitCore
import Testing

/// Reading an AI answer is read again through a failure that passes, and shown at once for one that won't.
struct PRAIAnswerTests {
    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost])
    func aNetworkFailurePasses(_ code: URLError.Code) {
        #expect(URLError(code).isPassingAIFailure)
    }

    @Test func theWorkerBusyOrDownPasses() {
        #expect(PRWorkerError.unavailable.isPassingAIFailure)
        #expect(PRWorkerError.limited.isPassingAIFailure)
    }

    @Test func aRefusalOrSignOutIsShown() {
        #expect(!PRWorkerError.refused("The model declined this PR.").isPassingAIFailure)
        #expect(!PRWorkerError.signedOut.isPassingAIFailure)
        #expect(!URLError(.badURL).isPassingAIFailure)
    }

    @Test func aMovedAnswerSaysSo() throws {
        let failure = try JSONDecoder().decode(PRAIFailure.self, from: Data(#"{"error":"moved on","moved":true}"#.utf8))
        #expect(failure.moved == true)
        let plain = try JSONDecoder().decode(PRAIFailure.self, from: Data(#"{"error":"boom"}"#.utf8))
        #expect(plain.moved == nil)
    }
}
