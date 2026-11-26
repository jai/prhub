import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// When a PR was opened, as its page's header says it (Jai's feedback, 2026-11-26: the PR did not say).
struct PRDetailOpenedTests {
    private func detail(createdAt: String?) throws -> PullRequestDetail {
        var payload = PRTestPayload.detail()
        if let createdAt {
            payload = "{\"createdAt\":\"\(createdAt)\"," + payload.dropFirst()
        }
        return try PullRequestDetail.decode(Data(payload.utf8))
    }

    @Test func aPRSaysHowLongAgoItWasOpened() throws {
        let detail = try detail(createdAt: "2026-11-23T07:02:00Z")
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-26T09:00:00Z"))
        let opened = try #require(detail.opened(now: now))
        #expect(opened.hasPrefix("opened "))
        #expect(opened.contains("3"), "three days before now: \(opened)")
        #expect(opened != detail.opened(now: now.addingTimeInterval(30 * 86400)), "it is told from now")
        #expect(detail.openedInFull?.contains("2026") == true, "the whole date names its year")
    }

    @Test func aDetailStoredBeforeTheWorkerSaidWhenSaysNothing() throws {
        let detail = try detail(createdAt: nil)
        #expect(detail.createdAt == nil)
        #expect(detail.opened() == nil)
        #expect(detail.openedInFull == nil)
    }
}
