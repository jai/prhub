import Foundation
@testable import PRKit
import Testing

struct PRAskReadProblemTests {
    @Test func anUnreachableWorkerIsQuietAndARefusalIsNot() {
        let unreachable = PRAskReadProblem(URLError(.networkConnectionLost))
        #expect(unreachable == .unreachable && !unreachable.isFailure)
        #expect(!unreachable.words.contains("network connection was lost"))
        let refused = PRAskReadProblem(PRWorkerError.refused("Ask is not set up on this Worker."))
        #expect(refused == .failed("Ask is not set up on this Worker.") && refused.isFailure)
    }
}
