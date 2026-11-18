import Foundation
@testable import PRKit
import Synchronization
import Testing

/// Key lines checked off as reviewed: at once on screen, kept by the Worker so another device shows them, at one head.
@MainActor
struct PRKeyLineReviewTests {
    private let storage = TestStorage()
    /// The Worker's `key-lines-reviewed` route, as docs/api.md has it, or a Worker that refuses or lacks it.
    final class Worker: Sendable {
        enum Mode { case keeps, refuses, lacksRoute, offline }

        private struct State {
            var reviewed: [String: Set<String>] = [:]
            var posts: [String] = []
            var mode = Mode.keeps
        }

        private let state = Mutex(State())

        var posts: [String] {
            state.withLock { $0.posts }
        }

        func set(_ mode: Mode) {
            state.withLock { $0.mode = mode }
        }

        /// What another device checked off.
        func seed(_ lines: Set<String>, at head: String) {
            state.withLock { $0.reviewed[head] = lines }
        }

        func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
            if state.withLock({ $0.mode == .offline }) {
                throw URLError(.notConnectedToInternet)
            }
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
                return try (JSONEncoder().encode(kept), answer(200, "").1)
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

    /// `directory`: the mirror's folder, shared by two sessions as by two launches.
    private func session(detail: String? = nil, in directory: URL? = nil) async throws -> PRSession {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { try await worker.exchange($0) }
        let directory = directory ?? storage.directory.appending(path: UUID().uuidString)
        let model = PRsModel(client: client, directory: directory, defaults: storage.defaults,
                             network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)
        var data = try FixtureContractTests.data("detail.json")
        if let detail {
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["head"] = detail
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let keyLines = try JSONDecoder().decode(PRKeyLines.self, from: Data(Self.lines.utf8))
        let session = try PRSession(
            ref: ref, title: nil, content: PRContent(detail: PullRequestDetail.decode(data), document: nil),
            keyLines: keyLines, tappedAt: 0, model: model
        )
        session.setContextLines(PRKeyLines.defaultContext)
        await session.loadKeyLines()
        return session
    }

    private func head(of session: PRSession) throws -> String {
        try #require(session.content?.detail.head)
    }

    @Test func aTickShowsAtOnceGoesToTheWorkerAndAnotherDeviceReadsIt() async throws {
        let phone = try await session()
        let item = phone.keyLineItems[1]
        let phoneMark = try #require(phone.setReviewed(true, item))
        #expect(phone.isReviewed(item) && phone.reviewedKeyLineCount == 1, "ticked before the Worker answers")
        await phoneMark.value
        #expect(worker.posts == ["a.swift:RIGHT:5=true"])

        let mac = try await session()
        #expect(!mac.isReviewed(item))
        await mac.loadReviewedKeyLines()
        #expect(mac.isReviewed(item) && mac.reviewedKeyLineCount == 1)

        let macMark = try #require(mac.setReviewed(false, item))
        await macMark.value
        await phone.loadReviewedKeyLines()
        #expect(!phone.isReviewed(item), "unticked on the Mac, unticked on the phone")
    }

    @Test func aRefusedTickGoesBackAndSaysWhy() async throws {
        let session = try await session()
        worker.set(.refuses)
        let item = session.keyLineItems[0]
        let marking = try #require(session.setReviewed(true, item))
        #expect(session.isReviewed(item))
        await marking.value
        #expect(!session.isReviewed(item))
        #expect(session.notice == .failed("Too many."))
    }

    @Test func aWorkerWithoutTheRouteKeepsTicksOnTheDevice() async throws {
        let session = try await session()
        worker.set(.lacksRoute)
        let item = session.keyLineItems[0]
        let marking = try #require(session.setReviewed(true, item))
        await marking.value
        await session.loadReviewedKeyLines()
        #expect(session.isReviewed(item) && session.notice == nil)
    }

    @Test func ticksBelongToTheHeadTheyWereMadeAt() async throws {
        let older = try await session()
        try worker.seed(["a.swift:RIGHT:1"], at: head(of: older))
        await older.loadReviewedKeyLines()
        #expect(older.reviewedKeyLineCount == 1)

        let newer = try await session(detail: String(repeating: "c", count: 40))
        await newer.loadReviewedKeyLines()
        #expect(newer.reviewedKeyLineCount == 0, "a new commit starts the review again")
    }

    @Test func ticksReadOnlineShowOfflineOnTheNextLaunch() async throws {
        let directory = storage.directory.appending(path: UUID().uuidString)
        let online = try await session(in: directory)
        try worker.seed(["a.swift:RIGHT:1"], at: head(of: online))
        await online.loadReviewedKeyLines()
        #expect(online.reviewedKeyLineCount == 1)

        worker.set(.offline)
        let relaunched = try await session(in: directory)
        await relaunched.loadReviewedKeyLines()
        #expect(relaunched.reviewedKeyLineCount == 1, "the kept ticks, with no network")
    }

    @Test func nextAndPreviousSkipTicksUntilAllAreTicked() async throws {
        let session = try await session()
        let items = session.keyLineItems
        let firstMark = try #require(session.setReviewed(true, items[1]))
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[0].id)
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[2].id, "the ticked one is passed over")
        session.stepKeyLine(by: -1)
        #expect(session.selectedKeyLine?.id == items[0].id)

        session.show(items[1])
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[2].id, "from a ticked one on show, on to the next open one")

        let secondMark = try #require(session.setReviewed(true, items[0]))
        let thirdMark = try #require(session.setReviewed(true, items[2]))
        session.stepKeyLine(by: 1)
        #expect(session.selectedKeyLine?.id == items[0].id, "all ticked: every one, in order")
        await firstMark.value
        await secondMark.value
        await thirdMark.value
    }
}

struct PRKeyLinesSummaryTests {
    /// A PR's page shows its summary from key lines the session already holds, at whatever context, and asks for none:
    /// on an API key, asking is what makes them.
    @MainActor @Test func aPRsPageHasItsSummaryFromKeyLinesAlreadyHeldAndAsksForNone() throws {
        let storage = TestStorage()
        defer { withExtendedLifetime(storage) {} }
        let asked = Mutex(0)
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { _ in
            asked.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let directory = storage.directory
        let model = PRsModel(client: client, directory: directory, defaults: storage.defaults,
                             network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)
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
}
