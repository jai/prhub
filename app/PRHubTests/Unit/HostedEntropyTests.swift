import Foundation
@testable import PRHubCore
import Testing

struct HostedEntropyTests {
    @Test func eachAttemptHasItsOwnStateAndVerifierInTheContractsAlphabet() throws {
        let first = try SignInAttempt.make()
        let second = try SignInAttempt.make()
        #expect(first.state != second.state && first.verifier != second.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-")
        for value in [first.state, first.verifier] {
            #expect((43 ... 128).contains(value.count))
            #expect(value.unicodeScalars.allSatisfy(allowed.contains))
        }
    }
}
