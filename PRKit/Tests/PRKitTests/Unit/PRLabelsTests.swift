import Foundation
@testable import PRKit
import PRKitTestSupport
import Synchronization
import Testing

/// A PR's labels put on and taken off: what goes to the Worker, the repo's labels as it answers them, and the session
/// that shows a change at once, takes GitHub's answer and puts a refused one back with GitHub's words.
@MainActor
struct PRLabelsTests {
    /// The Worker's labels route and its writes, as docs/api.md has them, or a Worker that lacks the route, refuses
    /// a write or holds its answer until the test lets it go.
    final class Worker: Sendable {
        enum Labels { case answers(canEdit: Bool), lacksRoute, fails }

        private struct State {
            var labels = Labels.answers(canEdit: true)
            var onPR = ["sample"]
            var writes: [String] = []
            var reads = 0
            var refusal: String?
            var isHolding = false
            var held: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        var writes: [String] {
            state.withLock { $0.writes }
        }

        var reads: Int {
            state.withLock { $0.reads }
        }

        func set(_ labels: Labels) {
            state.withLock { $0.labels = labels }
        }

        func refuse(_ words: String?) {
            state.withLock { $0.refusal = words }
        }

        /// Writes wait from now until `release`.
        func hold() {
            state.withLock { $0.isHolding = true }
        }

        func release() {
            let held = state.withLock { state in
                state.isHolding = false
                defer { state.held = [] }
                return state.held
            }
            for waiter in held {
                waiter.resume()
            }
        }

        static func detail(labels: [String]) -> String {
            let held = labels.map { #"{"name":"\#($0)","color":"d73a4a"}"# }.joined(separator: ",")
            return PRTestPayload.detail().replacing(#""labels":[]"#, with: #""labels":[\#(held)]"#)
        }

        func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let answer = { (status: Int, body: String) in
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if url.path().hasSuffix("/labels") {
                let labels = state.withLock { state in
                    state.reads += 1
                    return state.labels
                }
                switch labels {
                case .lacksRoute: return answer(404, "not found\n")
                case .fails: return answer(503, "")
                case let .answers(canEdit):
                    return answer(200, """
                    {"labels":[{"name":"bug","color":"d73a4a","description":"Something isn't working"},
                    {"name":"needs-design","color":"fbca04","description":null},
                    {"name":"sample","color":"8250DF","description":"A sample"}],"canEdit":\(canEdit)}
                    """)
                }
            }
            guard url.path().hasSuffix("/write") else {
                return answer(404, "not found\n")
            }
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
            let (kind, name) = (body["kind"] ?? "", body["name"] ?? "")
            let isHolding = state.withLock { state in
                state.writes.append("\(kind) \(name)")
                return state.isHolding
            }
            if isHolding {
                await withCheckedContinuation { waiter in
                    let goesOn = state.withLock { state in
                        guard state.isHolding else {
                            return true
                        }
                        state.held.append(waiter)
                        return false
                    }
                    if goesOn {
                        waiter.resume()
                    }
                }
            }
            return state.withLock { state in
                if let refusal = state.refusal {
                    return answer(422, #"{"error":"\#(refusal)"}"#)
                }
                state.onPR = kind == "label_add" ? state.onPR.filter { $0 != name } + [name] : state.onPR.filter { $0 != name }
                return answer(200, Self.detail(labels: state.onPR))
            }
        }
    }

    private let worker = Worker()
    private let ref = PullRequestRef(repo: "acme/web", number: 412)
    private let bug = PRRepoLabels.Label(name: "bug", color: "d73a4a", description: "Something isn't working")
    private let sample = PRRepoLabels.Label(name: "sample", color: "8250DF", description: "A sample")

    /// The PR with the label "sample" on it, over the scripted Worker.
    private func session() throws -> PRSession {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        let client = PRViewerClient(access: access) { try await worker.exchange($0) }
        let model = PRsModel(client: client, storage: .inMemory(), network: PRNetwork(isOnline: true))
        let detail = try PullRequestDetail.decode(Data(Worker.detail(labels: ["sample"]).utf8))
        return PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: nil), tappedAt: 0, model: model
        )
    }

    private func shown(_ session: PRSession) throws -> [String] {
        try session.shownLabels(in: #require(session.content?.detail)).map(\.name)
    }

    // MARK: - What goes to the Worker, and what it answers

    private func payload(_ write: PRWrite) -> [String: AnyHashable]? {
        (try? JSONEncoder().encode(write)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: AnyHashable] }
    }

    @Test func aLabelWriteCarriesItsKindAndTheLabelsNameAndNothingElse() {
        #expect(payload(.labelAdd(name: "bug")) == ["kind": "label_add", "name": "bug"])
        #expect(payload(.labelRemove(name: "needs-design")) == ["kind": "label_remove", "name": "needs-design"])
        #expect(PRWriteKind(.labelAdd(name: "bug")) == .labelAdd)
        #expect(PRWriteKind(.labelRemove(name: "bug")) == .labelRemove)
    }

    @Test func aLateRefusalNamesTheLabel() {
        let words = PRWrite.labelAdd(name: "bug").refusal(on: ref, reason: "Not allowed.")
        #expect(words == "GitHub refused adding the label “bug” on acme/web#412: Not allowed.")
    }

    @Test func theReposLabelsDecodeWithADescriptionOrNone() throws {
        let answer = """
        {"labels":[{"name":"bug","color":"d73a4a","description":"Something isn't working"},
        {"name":"needs-design","color":"fbca04","description":null}],"canEdit":false}
        """
        let labels = try JSONDecoder().decode(PRRepoLabels.self, from: Data(answer.utf8))
        #expect(labels.labels == [bug, PRRepoLabels.Label(name: "needs-design", color: "fbca04", description: nil)])
        #expect(!labels.canEdit)
    }

    // MARK: - Reading the repo's labels

    @Test func theListIsReadWhenItOpensAndOnlyOnce() async throws {
        let session = try session()
        #expect(session.labelEditing.load == .notRead && session.offersLabelEditing)
        await session.loadLabels()
        guard case let .ready(repo) = session.labelEditing.load else {
            Issue.record("The labels were not read: \(session.labelEditing.load)")
            return
        }
        #expect(repo.labels.map(\.name) == ["bug", "needs-design", "sample"] && repo.canEdit)
        #expect(session.hasLabel("sample") && !session.hasLabel("bug"))
        await session.loadLabels()
        #expect(worker.reads == 1)
    }

    @Test func aWorkerWithoutTheRouteLeavesTheChipsReadOnly() async throws {
        worker.set(.lacksRoute)
        let session = try session()
        await session.loadLabels()
        #expect(session.labelEditing.load == .unavailable)
        #expect(!session.offersLabelEditing, "the way in goes")
        #expect(session.toggleLabel(bug) == nil && worker.writes.isEmpty)
        #expect(try shown(session) == ["sample"], "the PR's labels still show")
    }

    @Test func aFailedReadSaysWhyAndIsReadAgainOnTryAgain() async throws {
        worker.set(.fails)
        let session = try session()
        await session.loadLabels()
        #expect(session.labelEditing.load == .failed("The Worker couldn't answer just now. Try again in a minute."))
        #expect(session.offersLabelEditing)
        worker.set(.answers(canEdit: true))
        await session.loadLabels()
        #expect(worker.reads == 1, "only Try again reads it again")
        await session.loadLabels(retry: true)
        #expect(session.canEditLabels)
    }

    // MARK: - Putting one on, taking one off

    @Test func aLabelPutOnShowsAtOnceAndThenIsGitHubs() async throws {
        let session = try session()
        await session.loadLabels()
        worker.hold()
        let sent = try #require(session.toggleLabel(bug))
        #expect(session.hasLabel("bug"), "on before the Worker answers")
        #expect(try shown(session) == ["sample", "bug"])
        #expect(try session.shownLabels(in: #require(session.content?.detail)).last?.color == "d73a4a", "in the repo's colour")
        #expect(session.content?.detail.labels.map(\.name) == ["sample"], "GitHub's own are not touched yet")
        #expect(session.toggleLabel(bug) == nil, "a second tap waits for the first")
        try await settle("the write reaches the Worker") { worker.writes == ["label_add bug"] }
        worker.release()
        await sent.value
        #expect(session.content?.detail.labels.map(\.name) == ["sample", "bug"], "the Worker's fresh detail")
        #expect(session.labelEditing.wanted.isEmpty && session.labelEditing.sending.isEmpty)
        #expect(try shown(session) == ["sample", "bug"] && session.labelEditing.problem == nil)
    }

    @Test func aLabelTakenOffGoesAtOnceAndThenIsGone() async throws {
        let session = try session()
        await session.loadLabels()
        worker.hold()
        let sent = try #require(session.toggleLabel(sample))
        #expect(!session.hasLabel("sample"))
        #expect(try shown(session).isEmpty)
        try await settle("the write reaches the Worker") { worker.writes == ["label_remove sample"] }
        worker.release()
        await sent.value
        #expect(session.content?.detail.labels.isEmpty == true && session.labelEditing.wanted.isEmpty)
    }

    @Test func aRefusedLabelIsPutBackWithGitHubsWords() async throws {
        let session = try session()
        await session.loadLabels()
        worker.refuse("This repo has no label named 'bug'.")
        let sent = try #require(session.toggleLabel(bug))
        #expect(session.hasLabel("bug"))
        await sent.value
        #expect(!session.hasLabel("bug"), "put back")
        #expect(try shown(session) == ["sample"])
        #expect(session.labelEditing.problem == "This repo has no label named 'bug'.")
        #expect(session.labelEditing.sending.isEmpty)
        // The next change clears the words, and a refused removal puts the label back on.
        let removal = try #require(session.toggleLabel(sample))
        #expect(session.labelEditing.problem == nil && !session.hasLabel("sample"))
        await removal.value
        #expect(session.hasLabel("sample") && session.labelEditing.problem != nil)
    }

    @Test func whereThePersonMayNotChangeLabelsNothingIsSent() async throws {
        worker.set(.answers(canEdit: false))
        let session = try session()
        await session.loadLabels()
        #expect(!session.canEditLabels && session.offersLabelEditing, "the list still opens, to be read")
        #expect(session.toggleLabel(bug) == nil)
        #expect(worker.writes.isEmpty && !session.hasLabel("bug"))
    }

    // MARK: - Sample PRs

    private func sampleModel(canEdit: Bool = true) -> PRsModel {
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Show a retry button", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: nil
        )
        var samples = PRSampleSet(
            samples: [.init(row: row, detail: Worker.detail(labels: ["sample"]), diff: "", keyLines: nil)],
            mergedReviewed: [], mergedMine: [], answersOnPhone: true
        )
        samples.repoLabels = PRRepoLabels(labels: PRSampleSet.sampleLabels, canEdit: canEdit)
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        return PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
    }

    @Test func aSampleAnswersTheLabelsReadOnThePhone() async throws {
        let labels = try await sampleModel().repoLabels(for: ref)
        #expect(labels.canEdit && labels.labels.count == 8)
        #expect(labels.labels.map(\.name) == labels.labels.map(\.name).sorted(), "sorted, as the Worker sends them")
        #expect(labels.labels.contains { $0.name == "bug" } && labels.labels.contains { $0.name == "needs-design" })
        #expect(labels.labels.contains { $0.name == "sample" }, "the label the sample PRs come with")
    }

    /// The panel's rows: the repo's labels, with a tick on each the PR has. Where they can't be changed they are read
    /// the same, and a press on one changes nothing.
    @Test(arguments: [true, false])
    func aSamplesListTicksThePRsOwnLabelsWhetherOrNotTheyCanBeChanged(canEdit: Bool) async throws {
        let model = sampleModel(canEdit: canEdit)
        let session = try model.session(for: #require(model.rows.first))
        await session.loadLabels()
        #expect(session.labelEditing.load == .ready(PRRepoLabels(labels: PRSampleSet.sampleLabels, canEdit: canEdit)))
        #expect(PRSampleSet.sampleLabels.filter { session.hasLabel($0.name) }.map(\.name) == ["sample"])
        #expect(session.canEditLabels == canEdit && session.offersLabelEditing)
        if !canEdit {
            #expect(session.toggleLabel(bug) == nil && !session.hasLabel("bug"), "a press changes nothing")
        }
    }

    @Test func aSampleKeepsALabelPutOnAndDropsOneTakenOff() async throws {
        let model = sampleModel()
        let added = try #require(try await model.write(.labelAdd(name: "needs-design"), to: ref).posted)
        #expect(added.labels.map(\.name) == ["sample", "needs-design"])
        #expect(added.labels.last?.color == "fbca04", "in the repo's colour for it")
        _ = try await model.write(.labelAdd(name: "needs-design"), to: ref)
        _ = try await model.write(.labelRemove(name: "sample"), to: ref)
        let row = try #require(model.rows.first)
        #expect(model.session(for: row).content?.detail.labels.map(\.name) == ["needs-design"], "once, and kept when it opens again")
    }

    @Test func aSampleRefusesALabelTheRepoDoesNotHaveAndAnyChangeWhereItMayNot() async throws {
        await #expect(throws: PRWorkerError.refused(#"This repo has no label named "kiwi"."#, isPermanent: true)) {
            try await sampleModel().write(.labelAdd(name: "kiwi"), to: ref)
        }
        await #expect(throws: PRWorkerError.refused("You can't change labels on this repo.", isPermanent: true)) {
            try await sampleModel(canEdit: false).write(.labelRemove(name: "sample"), to: ref)
        }
    }

    @Test func aSamplesLabelIsChangedThroughItsSession() async throws {
        let model = sampleModel()
        let session = try model.session(for: #require(model.rows.first))
        await session.loadLabels()
        await session.toggleLabel(bug)?.value
        #expect(try shown(session) == ["sample", "bug"] && session.notice == .sampleOnly)
    }
}
