import DurableNetworking
import Foundation
@testable import PRKit
import Testing

struct PRSessionIdentityTests {
    @MainActor
    @Test func twoOpensOfOnePRAreTwoSessionsAndEachKeepsItsOwnPR() {
        let model = PRsModel(client: PRViewerClient(access: .offline, transport: URLSessionTransport.background))
        let first = model.session(for: PullRequestRef(repo: "o/a", number: 1))
        let again = model.session(for: PullRequestRef(repo: "o/a", number: 1))
        let other = model.session(for: PullRequestRef(repo: "o/b", number: 2))
        #expect(first != again)
        #expect(first.label == "o/a#1" && other.label == "o/b#2")
        #expect(first.title == "o/a#1")
    }
}
