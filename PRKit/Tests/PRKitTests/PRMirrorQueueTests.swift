import Foundation
import Testing
@testable import PRKit

/// The mirror's queue (`PRMirror`): one download per file, six at a time, the newest list wins, and a pull waits for
/// the list alone.
@MainActor
struct PRMirrorQueueTests {
    /// A pr-worker on the phone: its list, and each PR's files after `delay`, or when a gated file is let go.
    actor Worker {
        var list: [PullRequestRow] = []
        var delay: Duration = .zero
        private(set) var requests: [String] = []
        private var gated: Set<String> = []
        /// Statuses to answer a path with, one per request, before it answers 200.
        private var statuses: [String: [Int]] = [:]
        private var bodies: [String: Data] = [:]
        private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]

        func set(list: [PullRequestRow], delay: Duration = .zero) {
            self.list = list
            self.delay = delay
        }

        func answer(_ path: String, statuses: [Int] = [], body: String? = nil) {
            self.statuses[path] = statuses
            bodies[path] = body.map { Data($0.utf8) }
        }

        func gate(_ path: String) {
            gated.insert(path)
        }

        func open(_ path: String) {
            gated.remove(path)
            for waiter in gates.removeValue(forKey: path) ?? [] {
                waiter.resume()
            }
        }

        func count(_ suffix: String) -> Int {
            requests.filter { $0.hasSuffix(suffix) }.count
        }

        func answer(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url?.path() ?? ""
            requests.append(path)
            let body: Data
            if path == "/prs" {
                body = try JSONSerialization.data(withJSONObject: [
                    "prs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)), "synced_at": 0,
                ])
            } else {
                if gated.contains(path) {
                    await withCheckedContinuation { gates[path, default: []].append($0) }
                } else if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                body = bodies[path] ?? Data(path.hasSuffix("/detail") ? Self.detail.utf8 : "diff --git a/f b/f\n".utf8)
            }
            let status = statuses[path]?.isEmpty == false ? statuses[path]!.removeFirst() : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        private static let detail = """
        {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
        "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"CLEAN","labels":[],"checks":[],
        "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
        """
    }

    private let worker = Worker()
    /// A run's own repo, so no file of another test's is already here.
    private let repo = "test/\(UUID().uuidString)"

    private func row(_ number: Int, revision: String = "r", detail: String = "d") -> PullRequestRow {
        PullRequestRow(
            repo: repo, number: number, title: "PR \(number)", head: "h", revision: revision, diff: .ready,
            detail: detail, status: nil
        )
    }

    private var client: PRViewerClient {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        return PRViewerClient(access: access) { try await worker.answer($0) }
    }

    /// Quick retries, so a test that fails a file several times takes a moment.
    private static let quick = PRMirror.RetryPolicy(
        first: .milliseconds(10), longest: .milliseconds(40), attempts: 3, deadline: .seconds(5), keepsUnlisted: .zero
    )

    /// A test's own mirror folder: another suite's sync prunes the shared one.
    private static func ownDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "pr-mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func mirror(in directory: URL? = nil) -> PRMirror {
        let directory = directory
            ?? URL.temporaryDirectory.appending(path: "pr-mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = PRMirror.savedRows(in: directory)
        return PRMirror(directory: directory, client: client, shown: saved, policy: Self.quick)
    }

    private func diffPath(_ row: PullRequestRow) -> String {
        "/prs/\(row.repo)/\(row.number)/diff"
    }

    private func detailPath(_ row: PullRequestRow) -> String {
        "/prs/\(row.repo)/\(row.number)/detail"
    }

    @Test func aPullReturnsWithTheListBeforeThePRsFilesHaveLanded() async throws {
        let rows = [row(1), row(2)]
        await worker.set(list: rows, delay: .seconds(2))
        let model = PRsModel(client: client, directory: Self.ownDirectory())
        let clock = ContinuousClock()
        let started = clock.now
        await model.refresh(.pull)
        #expect(clock.now - started < .seconds(1))
        #expect(model.rows.isEmpty, "a row shows only once its files are here")
        // The files take 2 s; a busy shared runner can take a few more.
        for _ in 0..<300 where model.rows.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.rows.map(\.id) == rows.map(\.id))
    }

    @Test func aPullWhileAWakeDownloadsWaitsForNoDownload() async throws {
        await worker.set(list: [row(1)], delay: .seconds(2))
        let model = PRsModel(client: client, directory: Self.ownDirectory())
        let wake = Task { await model.refresh(.silentPush) }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        await model.refresh(.pull)
        #expect(clock.now - started < .seconds(1))
        #expect(await wake.value == .changed)
        #expect(await worker.count("/diff") == 1, "the pull's list wanted the same file: it waited for that one")
    }

    @Test func twoSyncsOfOneListFetchEachFileOnce() async {
        let rows = [row(1), row(2), row(3)]
        await worker.set(list: rows, delay: .milliseconds(100))
        let mirror = mirror()
        _ = await mirror.begin(rows, generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try? await Task.sleep(for: .milliseconds(20))
        _ = await mirror.begin(rows, generation: 2)
        let second = await mirror.sync(generation: 2)
        #expect(await first.value == nil, "overtaken by the newer list")
        #expect(second?.rows.map(\.id) == rows.map(\.id))
        #expect(await worker.count("/diff") == 3)
        #expect(await worker.count("/detail") == 3)
    }

    @Test func anOlderListThatFinishesLastDoesNotReplaceTheNewerOne() async throws {
        let old = [row(1), row(2)]
        let new = [row(1)]
        await worker.gate(diffPath(row(2)))
        let mirror = mirror()
        _ = await mirror.begin(old, generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await Task.sleep(for: .milliseconds(100))
        _ = await mirror.begin(new, generation: 2)
        let second = await mirror.sync(generation: 2)
        await worker.open(diffPath(row(2)))
        #expect(await first.value == nil)
        #expect(second?.rows.map(\.id) == new.map(\.id))
        let saved = PRMirror.savedRows(in: mirror.directory)
        #expect(saved.map(\.id) == new.map(\.id))
        #expect(!mirror.isLocal(row(2)), "a download only the old list wanted was cancelled")
    }

    @Test func pruneKeepsAFileThatIsStillDownloading() async throws {
        let gone = row(1)
        await worker.gate(diffPath(gone))
        let mirror = mirror()
        _ = await mirror.begin([gone], generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await Task.sleep(for: .milliseconds(100))
        // The list moves on while the file is out; one by its name is already here, as if just written.
        _ = await mirror.begin([], generation: 2)
        let file = mirror.directory.appending(path: gone.diffFileName)
        try Data("diff".utf8).write(to: file)
        _ = await mirror.sync(generation: 2)
        #expect(FileManager.default.fileExists(atPath: file.path()))
        await worker.open(diffPath(gone))
        _ = await first.value
    }

    /// A Mac's app group folder is under `Library/Group Containers`: a space in the path hides no file.
    @Test func aMirrorInAFolderWithASpaceShowsItsRowsAndDownloadsThemOnce() async {
        let rows = [row(1)]
        await worker.set(list: rows)
        let directory = URL.temporaryDirectory
            .appending(path: "Group Containers \(UUID().uuidString)/pr-viewer", directoryHint: .isDirectory)
        let mirror = mirror(in: directory)
        _ = await mirror.begin(rows, generation: 1)
        let first = await mirror.sync(generation: 1)
        #expect(first?.rows.map(\.id) == rows.map(\.id))
        #expect(first?.isComplete == true)
        #expect(PRMirror.savedRows(in: directory).map(\.id) == rows.map(\.id))
        _ = await mirror.begin(rows, generation: 2)
        _ = await mirror.sync(generation: 2)
        #expect(await worker.count("/diff") == 1, "the second sync found the file on disk")
    }

    @Test func noMoreThanSixFilesDownloadAtOnce() async {
        let rows = (1...20).map { row($0) }
        await worker.set(list: rows, delay: .milliseconds(50))
        let mirror = mirror()
        _ = await mirror.begin(rows, generation: 1)
        let result = await mirror.sync(generation: 1)
        #expect(result?.rows.count == 20)
        #expect(await mirror.mostAtOnce == PRMirror.parallelDownloads)
    }

    // MARK: - Sets, failures and cancellation

    @Test func aNewRevisionShowsOnlyWithAllItsFilesAndTheOldOneUntilThen() async throws {
        let old = row(1, revision: "a", detail: "d1")
        let new = row(1, revision: "b", detail: "d2")
        let mirror = mirror()
        _ = await mirror.begin([old], generation: 1)
        _ = await mirror.sync(generation: 1)
        await worker.gate(detailPath(new))
        _ = await mirror.begin([new], generation: 2)
        let second = Task { await mirror.sync(generation: 2) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: mirror.directory.appending(path: new.diffFileName).path()))
        #expect(PRMirror.savedRows(in: mirror.directory).map(\.revision) == ["a"], "the new diff alone is no revision")
        await worker.open(detailPath(new))
        #expect(await second.value?.rows.map(\.revision) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: mirror.directory.appending(path: old.diffFileName).path()))
    }

    @Test func aPayloadThatDoesNotReadNeverLands() async {
        let item = row(1)
        await worker.answer(detailPath(item), body: "<html>Bad gateway</html>")
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        let result = await mirror.sync(generation: 1)
        #expect(!FileManager.default.fileExists(atPath: mirror.directory.appending(path: item.detailFileName).path()))
        #expect(result?.rows.isEmpty == true && result?.failed == [item.id])
        #expect(await worker.count("/detail") == Self.quick.attempts)
    }

    @Test func aPassingFailureIsTriedAgainAndOneGitHubWontServeIsNot() async {
        let passing = row(1)
        let gone = row(2)
        await worker.answer(diffPath(passing), statuses: [503, 502])
        await worker.answer(diffPath(gone), statuses: [404, 404, 404])
        let mirror = mirror()
        _ = await mirror.begin([passing, gone], generation: 1)
        let result = await mirror.sync(generation: 1)
        #expect(result?.rows.map(\.id) == [passing.id], "one failing PR holds up no other")
        #expect(result?.failed == [gone.id])
        #expect(await worker.count("\(passing.number)/diff") == 3)
        #expect(await worker.count("\(gone.number)/diff") == 1)
    }

    @Test func aFailedFileWaitsForAPullWhichTriesItAtOnce() async {
        let item = row(1)
        await worker.answer(diffPath(item), statuses: [404])
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        _ = await mirror.sync(generation: 1)
        _ = await mirror.begin([item], generation: 2)
        #expect(await mirror.sync(generation: 2)?.failed == [item.id])
        #expect(await worker.count("/diff") == 1, "a wake leaves it alone")
        _ = await mirror.begin([item], generation: 3, retry: true)
        let pulled = await mirror.sync(generation: 3)
        #expect(pulled?.rows.map(\.id) == [item.id] && pulled?.failed.isEmpty == true)
    }

    @Test func aRowWhoseFileWentMissingIsDownloadedAgainAfterARestart() async throws {
        let item = row(1)
        let directory = URL.temporaryDirectory
            .appending(path: "pr-mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
        let first = mirror(in: directory)
        _ = await first.begin([item], generation: 1)
        _ = await first.sync(generation: 1)
        try FileManager.default.removeItem(at: directory.appending(path: item.diffFileName))
        #expect(PRMirror.savedRows(in: directory).isEmpty, "a row with a file gone is not shown")
        let relaunched = mirror(in: directory)
        _ = await relaunched.begin([item], generation: 1)
        #expect(await relaunched.sync(generation: 1)?.rows.map(\.id) == [item.id])
        #expect(await worker.count("/diff") == 2)
    }

    @Test func aCancelledDownloadLeavesNothingAndIsNoFailure() async throws {
        let item = row(1)
        await worker.gate(detailPath(item))
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await Task.sleep(for: .milliseconds(100))
        _ = await mirror.begin([], generation: 2)
        await worker.open(detailPath(item))
        #expect(await first.value == nil)
        #expect(!FileManager.default.fileExists(atPath: mirror.directory.appending(path: item.detailFileName).path()))
        _ = await mirror.begin([item], generation: 3)
        let again = await mirror.sync(generation: 3)
        #expect(again?.rows.map(\.id) == [item.id] && again?.failed.isEmpty == true)
    }
}
