import Foundation
import Synchronization
import Testing
@testable import PRKit

/// Key lines checked off as reviewed: at once on screen, kept by the Worker so another device shows them, at one head.
@MainActor
@Suite(.enabled(if: RepoFixtures.areHere, "starts from docs/fixtures/detail.json"))
struct PRKeyLineReviewTests {
    /// The Worker's `key-lines-reviewed` route, as docs/api.md has it, or a Worker that refuses or lacks it.
    final class Worker: Sendable {
        enum Mode { case keeps, refuses, lacksRoute }

        private struct State {
            var reviewed: [String: Set<String>] = [:]
            var posts: [String] = []
            var mode = Mode.keeps
        }

        private let state = Mutex(State())

        var posts: [String] { state.withLock { $0.posts } }

        func set(_ mode: Mode) {
            state.withLock { $0.mode = mode }
        }

        /// What another device checked off.
        func seed(_ lines: Set<String>, at head: String) {
            state.withLock { $0.reviewed[head] = lines }
        }

        func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let answer = { (status: Int, body: String) in
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let (mode, reviewed) = try state.withLock { state -> (Mode, (head: String, lines: Set<String>)?) in
                guard request.httpMethod == "POST" else {
                    let head = query.first { $0.name == "head" }?.value ?? ""
                    return (state.mode, (head, state.reviewed[head] ?? []))
                }
                let mark = try JSONDecoder().decode(Mark.self, from: request.httpBody ?? Data())
                state.posts.append("\(mark.line)=\(mark.reviewed)")
                guard state.mode == .keeps else {
                    return (state.mode, nil)
                }
                var lines = state.reviewed[mark.head] ?? []
                if mark.reviewed {
                    lines.insert(mark.line)
                } else {
                    lines.remove(mark.line)
                }
                state.reviewed[mark.head] = lines
                return (state.mode, (mark.head, lines))
            }
            switch mode {
            case .lacksRoute: return answer(404, "not found\n")
            case .refuses where request.httpMethod == "POST": return answer(400, #"{"error":"Too many."}"#)
            default:
                let kept = PRReviewedKeyLines(head: reviewed?.head ?? "", reviewed: reviewed?.lines ?? [])
                return (try JSONEncoder().encode(kept), answer(200, "").1)
            }
        }

        private struct Mark: Decodable {
            let head: String
            let line: String
            let reviewed: Bool
        }
    }

    private let worker = Worker()
    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private static let lines = """
    {"items":[
      {"path":"a.swift","line":1,"side":"RIGHT","kind":"risk","why":"one"},
      {"path":"a.swift","line":5,"side":"RIGHT","kind":"decision","why":"two"},
      {"path":"b.swift","line":2,"side":"LEFT","kind":"logic","why":"three"}
    ],"context":100,"leftOut":[]}
    """

    private func session(detail: String? = nil) async throws -> PRSession {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { try await worker.exchange($0) }
        let directory = URL.temporaryDirectory.appending(path: "key-line-review-\(UUID().uuidString)")
        let model = PRsModel(client: client, directory: directory)
        var data = try FixtureContractTests.data("detail.json")
        if let detail {
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["head"] = detail
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let keyLines = try JSONDecoder().decode(PRKeyLines.self, from: Data(Self.lines.utf8))
        let session = PRSession(
            ref: ref, title: nil, content: PRContent(detail: try PullRequestDetail.decode(data), document: nil),
            keyLines: keyLines, tappedAt: 0, model: model
        )
        session.setContextLines(PRKeyLines.defaultContext)
        await session.loadKeyLines()
        return session
    }

    private func head(of session: PRSession) throws -> String {
        try #require(session.content?.detail.head)
    }

    /// Until the session's send has had its answer.
    private func settle(_ session: PRSession, posts: Int) async throws {
        for _ in 0..<200 where worker.posts.count < posts {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func aTickShowsAtOnceGoesToTheWorkerAndAnotherDeviceReadsIt() async throws {
        let phone = try await session()
        let item = phone.keyLineItems[1]
        phone.setReviewed(true, item)
        #expect(phone.isReviewed(item) && phone.reviewedKeyLineCount == 1, "ticked before the Worker answers")
        try await settle(phone, posts: 1)
        #expect(worker.posts == ["a.swift:RIGHT:5=true"])

        let mac = try await session()
        #expect(!mac.isReviewed(item))
        await mac.loadReviewedKeyLines()
        #expect(mac.isReviewed(item) && mac.reviewedKeyLineCount == 1)

        mac.setReviewed(false, item)
        try await settle(mac, posts: 2)
        await phone.loadReviewedKeyLines()
        #expect(!phone.isReviewed(item), "unticked on the Mac, unticked on the phone")
    }

    @Test func aRefusedTickGoesBackAndSaysWhy() async throws {
        let session = try await session()
        worker.set(.refuses)
        let item = session.keyLineItems[0]
        session.setReviewed(true, item)
        #expect(session.isReviewed(item))
        try await settle(session, posts: 1)
        #expect(!session.isReviewed(item))
        #expect(session.notice == .failed("Too many."))
    }

    @Test func aWorkerWithoutTheRouteKeepsTicksOnTheDevice() async throws {
        let session = try await session()
        worker.set(.lacksRoute)
        let item = session.keyLineItems[0]
        session.setReviewed(true, item)
        try await settle(session, posts: 1)
        await session.loadReviewedKeyLines()
        #expect(session.isReviewed(item) && session.notice == nil)
    }

    @Test func ticksBelongToTheHeadTheyWereMadeAt() async throws {
        let older = try await session()
        worker.seed(["a.swift:RIGHT:1"], at: try head(of: older))
        await older.loadReviewedKeyLines()
        #expect(older.reviewedKeyLineCount == 1)

        let newer = try await session(detail: String(repeating: "c", count: 40))
        await newer.loadReviewedKeyLines()
        #expect(newer.reviewedKeyLineCount == 0, "a new commit starts the review again")
    }

    @Test func nextAndPreviousSkipTicksUntilAllAreTicked() async throws {
        let session = try await session()
        let items = session.keyLineItems
        session.setReviewed(true, items[1])
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[0].id)
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[2].id, "the ticked one is passed over")
        session.stepKeyLine(by: -1)
        #expect(session.selectedKeyLine?.id == items[0].id)

        session.show(items[1])
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[2].id, "from a ticked one on show, on to the next open one")

        session.setReviewed(true, items[0])
        session.setReviewed(true, items[2])
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[0].id, "all ticked: every one, in order")
        try await settle(session, posts: 3)
    }
}

struct PRKeyLinesSummaryTests {
    @Test func aSummaryReadsWithItsRiskBugsAndPointsAndAnOlderAnswerHasNone() throws {
        let json = #"""
        {"items": [], "context": 100, "leftOut": [],
         "summary": {"risk": "high", "riskWhy": "Drops a column.", "points": ["Drops users.email"],
                     "bugs": [{"path": "db/m.sql", "line": 3, "side": "RIGHT", "why": "No backfill."}]}}
        """#
        let lines = try JSONDecoder().decode(PRKeyLines.self, from: Data(json.utf8))
        #expect(lines.summary?.riskTitle == "High risk" && lines.summary?.bugsTitle == "1 bug found")
        #expect(lines.summary?.bugs.first?.asItem.kind == "risk")
        let older = try JSONDecoder().decode(PRKeyLines.self, from: Data(#"{"items": [], "context": 0, "leftOut": []}"#.utf8))
        #expect(older.summary == nil)
    }

    /// A PR's page shows its summary from key lines the session already holds, at whatever context, and asks for none:
    /// on an API key, asking is what makes them.
    @MainActor @Test func aPRsPageHasItsSummaryFromKeyLinesAlreadyHeldAndAsksForNone() throws {
        let asked = Mutex(0)
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { _ in
            asked.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let directory = URL.temporaryDirectory.appending(path: "summary-\(UUID().uuidString)")
        let model = PRsModel(client: client, directory: directory)
        let json = #"""
        {"items": [], "context": 10, "leftOut": [],
         "summary": {"risk": "low", "riskWhy": "", "points": ["One"], "bugs": []}}
        """#
        let held = try JSONDecoder().decode(PRKeyLines.self, from: Data(json.utf8))
        let ref = PullRequestRef(repo: "acme/web", number: 1)
        let session = PRSession(ref: ref, title: nil, content: nil, keyLines: held, tappedAt: 0, model: model)
        session.setContextLines(PRKeyLines.defaultContext)
        #expect(session.summary?.points == ["One"])
        #expect(PRSession(ref: ref, title: nil, content: nil, tappedAt: 0, model: model).summary == nil)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func theSummarysHeadingsSayTheRiskAndCountTheBugs() throws {
        func summary(risk: String, bugs: Int) throws -> PRKeyLines.Summary {
            let bug = #"{"path": "a", "line": 1, "side": "RIGHT", "why": "w"}"#
            let all = Array(repeating: bug, count: bugs).joined(separator: ",")
            let json = #"{"risk": "\#(risk)", "riskWhy": "", "points": [], "bugs": [\#(all)]}"#
            return try JSONDecoder().decode(PRKeyLines.Summary.self, from: Data(json.utf8))
        }
        #expect(try summary(risk: "low", bugs: 0).riskTitle == "Low risk")
        #expect(try summary(risk: "medium", bugs: 0).bugsTitle == "No bugs found")
        #expect(try summary(risk: "high", bugs: 3).bugsTitle == "3 bugs found")
    }

    @Test func oneKeyLineIsCountedAsOne() {
        #expect(PRKeyLines.counted(1) == "1 key line")
        #expect(PRKeyLines.counted(0) == "0 key lines" && PRKeyLines.counted(3) == "3 key lines")
    }
}
