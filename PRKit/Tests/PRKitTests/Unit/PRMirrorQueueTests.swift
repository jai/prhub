import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// The mirror's queue (`PRMirror`): one download per file, six at a time, the newest list wins, and a pull waits for
/// the list alone. Its folder is in memory; `PRKitIntegrationTests`' suite of this name keeps the checks of a real one.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PRMirrorQueueTests {
    private let worker = PRMirrorWorker()
    private let files = InMemoryFileStore()
    private let repo = "acme/api"

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

    /// Retries whose waits pass at once, with no jitter, so a test that fails a file several times waits on no clock.
    private static let quick = PRMirror.RetryPolicy(
        attempts: 3, deadline: .seconds(5), keepsUnlisted: .zero, jitter: { 1 }, sleep: { _ in try Task.checkCancellation() }
    )

    /// A mirror of `files`, starting from the rows they hold, as at a launch.
    private func mirror() -> PRMirror {
        PRMirror(files: files, client: client, shown: PRMirror.savedRows(in: files), policy: Self.quick)
    }

    private func model() -> PRsModel {
        PRsModel(client: client, storage: .inMemory(mirror: files), network: PRNetwork(isOnline: true))
    }

    private func diffPath(_ row: PullRequestRow) -> String {
        "/prs/\(row.repo)/\(row.number)/diff"
    }

    private func detailPath(_ row: PullRequestRow) -> String {
        "/prs/\(row.repo)/\(row.number)/detail"
    }

    @Test func aPullReturnsWithTheListBeforeThePRsFilesHaveLanded() async throws {
        let rows = [row(1), row(2)]
        await worker.set(list: rows)
        for row in rows {
            await worker.gate(diffPath(row))
        }
        let model = model()
        await model.refresh(.pull)
        #expect(model.rows.isEmpty, "a row shows only once its files are here")
        for row in rows {
            try await worker.waitForRequest(diffPath(row))
            await worker.open(diffPath(row))
        }
        await model.refresh(.silentPush)
        #expect(model.rows.map(\.id) == rows.map(\.id))
    }

    @Test func aPullWhileAWakeDownloadsWaitsForNoDownload() async throws {
        let item = row(1)
        await worker.set(list: [item])
        await worker.gate(diffPath(item))
        let model = model()
        let wake = Task { await model.refresh(.silentPush) }
        try await worker.waitForRequest(diffPath(item))
        await model.refresh(.pull)
        #expect(model.rows.isEmpty, "the pull returns while the wake's download is still blocked")
        await worker.open(diffPath(item))
        #expect(await wake.value == .changed)
        #expect(await worker.count("/diff") == 1, "the pull shares the download already in flight")
    }

    @Test func twoSyncsOfOneListFetchEachFileOnce() async throws {
        let rows = [row(1), row(2), row(3)]
        await worker.set(list: rows)
        await worker.gate(diffPath(rows[0]))
        let mirror = mirror()
        _ = await mirror.begin(rows, generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await worker.waitForRequest(diffPath(rows[0]))
        _ = await mirror.begin(rows, generation: 2)
        let second = Task { await mirror.sync(generation: 2) }
        await worker.open(diffPath(rows[0]))
        #expect(await first.value == nil, "overtaken by the newer list")
        #expect(await second.value?.rows.map(\.id) == rows.map(\.id))
        #expect(await worker.count("/diff") == 3)
        #expect(await worker.count("/detail") == 3)
    }

    @Test func aFileThatLandsBeforeAQueuedRequestIsNotDownloadedAgain() async {
        let item = row(1)
        let mirror = mirror()
        let client = client
        #expect(!mirror.fileExists(item.diffFileName))
        let first = await mirror.file(item.diffFileName, check: { !$0.isEmpty }, read: {
            try await client.diff(item)
        })
        #expect(first == .landed)
        // A second caller can pass its existence check before the first download lands, then enter the actor later.
        let second = await mirror.file(item.diffFileName, check: { !$0.isEmpty }, read: {
            try await client.diff(item)
        })
        #expect(second == .landed)
        let downloads = await worker.count("/diff")
        #expect(downloads == 1)
    }

    @Test func anOlderListThatFinishesLastDoesNotReplaceTheNewerOne() async throws {
        let old = [row(1), row(2)]
        let new = [row(1)]
        await worker.gate(diffPath(row(2)))
        let mirror = mirror()
        _ = await mirror.begin(old, generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await worker.waitForRequest(diffPath(row(2)))
        _ = await mirror.begin(new, generation: 2)
        let second = await mirror.sync(generation: 2)
        await worker.open(diffPath(row(2)))
        #expect(await first.value == nil)
        #expect(second?.rows.map(\.id) == new.map(\.id))
        #expect(PRMirror.savedRows(in: files).map(\.id) == new.map(\.id))
        #expect(!mirror.isLocal(row(2)), "a download only the old list wanted was cancelled")
    }

    @Test func pruneKeepsAFileThatIsStillDownloading() async throws {
        let gone = row(1)
        await worker.gate(diffPath(gone), holdsAfterCancellation: true)
        let mirror = mirror()
        _ = await mirror.begin([gone], generation: 1)
        let first = Task { await mirror.sync(generation: 1) }
        try await worker.waitForRequest(diffPath(gone))
        // The list moves on while the file is out; one by its name is already here, as if just written.
        _ = await mirror.begin([], generation: 2)
        try files.write(Data("diff".utf8), to: gone.diffFileName)
        _ = await mirror.sync(generation: 2)
        #expect(files.exists(gone.diffFileName))
        await worker.open(diffPath(gone))
        _ = await first.value
    }

    /// Serverless-Operations#649 on 2026-11-16: an alert tapped 2.5 hours after it came, its PR on no list. Prune had
    /// removed the files its prefetch brought, and the PR waited 7.5 s on the network.
    @Test func pruneKeepsAnAlertsFilesWhileItCanBeTapped() async throws {
        let rows = [row(1)]
        await worker.set(list: rows)
        let mirror = mirror()
        for name in ["alerted.diff", "expired.diff"] {
            try files.write(Data("diff".utf8), to: name)
        }
        let alerted = PRAlertedFiles(store: files)
        alerted.note(["expired.diff"], at: Date(timeIntervalSince1970: 0))
        alerted.note(["alerted.diff"])
        _ = await mirror.begin(rows, generation: 1)
        _ = await mirror.sync(generation: 1)
        #expect(files.exists("alerted.diff"), "an alert's PR on no list, kept past keepsUnlisted")
        #expect(files.exists(PRAlertedFiles.fileName))
        #expect(!files.exists("expired.diff"), "this sync did prune")
    }

    @Test func noMoreThanSixFilesDownloadAtOnce() async throws {
        let rows = (1 ... 20).map { row($0) }
        await worker.set(list: rows)
        await worker.gateAll()
        let mirror = mirror()
        _ = await mirror.begin(rows, generation: 1)
        let syncing = Task { await mirror.sync(generation: 1) }
        defer { syncing.cancel() }
        try await worker.waitForRequests(PRMirror.parallelDownloads)
        #expect(await worker.requests.count == PRMirror.parallelDownloads, "every available slot is held")
        await worker.openAll()
        let result = await syncing.value
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
        try await settle("new diff landed while the detail is held") { mirror.fileExists(new.diffFileName) }
        #expect(PRMirror.savedRows(in: files).map(\.revision) == ["a"], "the new diff alone is no revision")
        await worker.open(detailPath(new))
        #expect(await second.value?.rows.map(\.revision) == ["b"])
        #expect(!files.exists(old.diffFileName))
    }

    @Test func aPayloadThatDoesNotReadNeverLands() async {
        let item = row(1)
        await worker.answer(detailPath(item), body: "<html>Bad gateway</html>")
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        let result = await mirror.sync(generation: 1)
        #expect(!files.exists(item.detailFileName))
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

    /// An open PR with no changes (2026-11-14, 0 files on GitHub): its diff is empty, the mirror refused it as
    /// unreadable on every try, and the list said "1 of 125 PRs could not be downloaded" whatever was pulled.
    @Test func aPRThatChangesNothingLandsWithItsEmptyDiff() async throws {
        let item = row(1)
        await worker.answer(diffPath(item), body: "")
        await worker.gate(diffPath(item))
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        let syncing = Task { await mirror.sync(generation: 1) }
        // Empty diff validation reads the detail's changedFiles: the diff lands only after the detail is here.
        do {
            try await settle("detail is available to validate the empty diff") { mirror.fileExists(item.detailFileName) }
        } catch {
            await worker.open(diffPath(item))
            _ = await syncing.value
            throw error
        }
        await worker.open(diffPath(item))
        let result = await syncing.value
        #expect(result?.rows.map(\.id) == [item.id] && result?.failed.isEmpty == true && result?.isComplete == true)
        // It opens: a description, and a diff with no files.
        guard case let .document(document, _)? = model().session(for: item).content?.diff else {
            Issue.record("the PR has no content, or its diff reads as too large")
            return
        }
        #expect(document.files.isEmpty)
    }

    @Test func anEmptyDiffOfAPRWithChangesIsNotTaken() async {
        let item = row(1)
        await worker.answer(diffPath(item), body: "")
        await worker.answer(detailPath(item), body: PRTestPayload.detail(additions: 4, deletions: 1, changedFiles: 2))
        let mirror = mirror()
        _ = await mirror.begin([item], generation: 1)
        let result = await mirror.sync(generation: 1)
        #expect(result?.rows.isEmpty == true && result?.failed == [item.id])
        #expect(await worker.count("/diff") == 3, "tried as any answer that does not read")
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

    @Test func aRowWhoseFileWentMissingIsDownloadedAgainAfterARestart() async {
        let item = row(1)
        let first = mirror()
        _ = await first.begin([item], generation: 1)
        _ = await first.sync(generation: 1)
        files.remove(item.diffFileName)
        #expect(PRMirror.savedRows(in: files).isEmpty, "a row with a file gone is not shown")
        let relaunched = mirror()
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
        try await worker.waitForRequest(detailPath(item))
        _ = await mirror.begin([], generation: 2)
        await worker.open(detailPath(item))
        #expect(await first.value == nil)
        #expect(!files.exists(item.detailFileName))
        _ = await mirror.begin([item], generation: 3)
        let again = await mirror.sync(generation: 3)
        #expect(again?.rows.map(\.id) == [item.id] && again?.failed.isEmpty == true)
    }
}
