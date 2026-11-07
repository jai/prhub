import Foundation
import Testing
@testable import PRHub

/// The setup link pr-worker's `npm run pair` prints (docs/api.md), read as the app reads a scan, a paste or a tap.
struct SetupLinkTests {
    @Test func readsTheLinkTheWorkerPrints() throws {
        let link = try SetupLink.parse(
            "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA"
        )
        #expect(link.worker.absoluteString == "https://pr-review.alex.workers.dev")
        #expect(link.code == "7KQ2M9XA")
        #expect(link.displayCode == "7KQ2-M9XA")
    }

    @Test func takesTheCodeWithoutRegardToCaseSpacesOrHyphens() throws {
        let link = try SetupLink.parse(
            "  PRHub://SETUP?worker=https%3A%2F%2FPR-Review.Alex.workers.dev%2F&code=7kq2-m9 xa\n"
        )
        #expect(link.worker.absoluteString == "https://pr-review.alex.workers.dev")
        #expect(link.code == "7KQ2M9XA")
    }

    @Test func keepsAPort() throws {
        let link = try SetupLink.parse("prhub://setup?worker=https%3A%2F%2Fpager.example.com%3A8443&code=7KQ2M9XA")
        #expect(link.worker.absoluteString == "https://pager.example.com:8443")
    }

    @Test(arguments: [
        "https://pr-review.alex.workers.dev",
        "prhub://pair?worker=https%3A%2F%2Fa.example&code=7KQ2M9XA",
        // The earlier public app's scheme: PRHub registers `prhub` alone.
        "agentpager://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9XA",
        "prhub://setup/extra?worker=https%3A%2F%2Fa.example&code=7KQ2M9XA",
        "not a link at all",
        "",
    ])
    func refusesWhatIsNotASetupLink(_ text: String) {
        #expect(throws: SetupLink.Failure.notASetupLink) { try SetupLink.parse(text) }
    }

    @Test(arguments: [
        "prhub://setup?code=7KQ2M9XA",
        "prhub://setup?worker=http%3A%2F%2Fa.example&code=7KQ2M9XA",
        "prhub://setup?worker=https%3A%2F%2Fa.example%2Fpath&code=7KQ2M9XA",
        "prhub://setup?worker=https%3A%2F%2Fa.example%3Fq%3D1&code=7KQ2M9XA",
        "prhub://setup?worker=https%3A%2F%2Fuser%3Apw%40a.example&code=7KQ2M9XA",
        "prhub://setup?worker=https%3A%2F%2F&code=7KQ2M9XA",
    ])
    func refusesAWorkerThatIsNotAnHTTPSHost(_ text: String) {
        #expect(throws: SetupLink.Failure.badWorker) { try SetupLink.parse(text) }
    }

    @Test(arguments: [
        "prhub://setup?worker=https%3A%2F%2Fa.example",
        "prhub://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9X",
        "prhub://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9XAB",
        // I, L, O and U are not in the Worker's alphabet.
        "prhub://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9XI",
        "prhub://setup?worker=https%3A%2F%2Fa.example&code=OOOOLLLL",
        "prhub://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9X%21",
    ])
    func refusesACodeOutsideTheAlphabet(_ text: String) {
        #expect(throws: SetupLink.Failure.badCode) { try SetupLink.parse(text) }
    }

    @Test func typedValuesTakeAnAddressWithoutAScheme() throws {
        let link = try SetupLink(worker: " pr-review.alex.workers.dev ", code: "7kq2-m9xa")
        #expect(link.worker.absoluteString == "https://pr-review.alex.workers.dev")
        #expect(link.code == "7KQ2M9XA")
        #expect(throws: SetupLink.Failure.badWorker) { try SetupLink(worker: "http://a.example", code: "7KQ2M9XA") }
        #expect(throws: SetupLink.Failure.badCode) { try SetupLink(worker: "a.example", code: "7KQ2") }
    }
}
