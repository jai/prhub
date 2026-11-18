import Foundation
@testable import PRKit
import Synchronization
import Testing

/// A pull on a PR's page: the PR as GitHub has it now, over the copy on screen.
@MainActor
struct PRPullToRefreshTests {
    private let preferences = TestPreferences()
    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private static let lines = """
    {"items":[{"path":"a.swift","line":1,"side":"RIGHT","kind":"risk","why":"one"}],"context":100,"leftOut":[]}
    """

    /// The Worker's live detail and diff, or its refusal.
    final class Worker: Sendable {
        private let state = Mutex<(detail: Data?, paths: [String])>((nil, []))

        var paths: [String] {
            state.withLock { $0.paths }
        }

        /// Nil: the Worker refuses.
        func serve(_ detail: Data?) {
            state.withLock { $0.detail = detail }
        }

        func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let detail = state.withLock { state in
                state.paths.append(url.path)
                return state.detail
            }
            let answer = { (status: Int, body: Data) in
                (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard let detail else {
                return answer(400, Data(#"{"error":"GitHub said no."}"#.utf8))
            }
            return url.path.hasSuffix("/diff") ? answer(200, Data()) : answer(200, detail)
        }
    }

    private let worker = Worker()

    private func detail(head: String, title: String) throws -> Data {
        var object = try #require(
            try JSONSerialization.jsonObject(with: FixtureContractTests.data("detail.json")) as? [String: Any]
        )
        object["head"] = head
        object["title"] = title
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func session() throws -> PRSession {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { try await worker.exchange($0) }
        let directory = URL.temporaryDirectory.appending(path: "pull-to-refresh-\(UUID().uuidString)")
        let model = PRsModel(client: client, directory: directory, defaults: preferences.defaults)
        let keyLines = try JSONDecoder().decode(PRKeyLines.self, from: Data(Self.lines.utf8))
        return try PRSession(
            ref: ref, title: nil,
            content: PRContent(detail: PullRequestDetail.decode(detail(head: "old", title: "Before")), document: nil),
            keyLines: keyLines, tappedAt: 0, model: model
        )
    }

    @Test func aPullShowsThePRAsGitHubHasItNowAndDropsTheOlderCommitsKeyLines() async throws {
        let session = try session()
        #expect(session.heldKeyLines != nil)
        try worker.serve(detail(head: "new", title: "After"))
        await session.pullToRefresh()
        #expect(session.content?.detail.head == "new" && session.title == "After")
        #expect(session.heldKeyLines == nil, "key lines of the older commit")
        #expect(worker.paths.contains("/prs/acme/api/7/detail"), "read live, not at a version")
    }

    @Test func aPullAtTheSameCommitKeepsItsKeyLines() async throws {
        let session = try session()
        try worker.serve(detail(head: "old", title: "Retitled"))
        await session.pullToRefresh()
        #expect(session.title == "Retitled" && session.heldKeyLines != nil)
    }

    @Test func aFailedPullLeavesThePRUpAndSaysWhy() async throws {
        let session = try session()
        worker.serve(nil)
        await session.pullToRefresh()
        #expect(session.title == "Before")
        if session.model.network.isOnline {
            guard case let .failed(words) = session.notice else {
                Issue.record("no notice")
                return
            }
            #expect(words.hasPrefix("Didn't refresh."))
        }
    }
}
