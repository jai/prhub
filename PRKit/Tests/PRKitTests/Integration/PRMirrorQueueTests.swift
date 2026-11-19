import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// The mirror's queue (`PRMirror`) in a real folder: what a folder on disk changes. `PRKitUnitTests`' suite of this name
/// holds the queue's own checks, in memory.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PRMirrorQueueTests {
    private let worker = PRMirrorWorker()
    private let storage = TestStorage()
    /// A run's own repo, so no file of another test's is already here.
    private let repo = "test/\(UUID().uuidString)"

    private func row(_ number: Int) -> PullRequestRow {
        PullRequestRow(
            repo: repo, number: number, title: "PR \(number)", head: "h", revision: "r", diff: .ready, detail: "d",
            status: nil
        )
    }

    private var client: PRViewerClient {
        let worker = worker
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        return PRViewerClient(access: access) { try await worker.answer($0) }
    }

    /// Retries whose waits pass at once, with no jitter, and prune that spares no unlisted file for its age.
    private static let quick = PRMirror.RetryPolicy(
        attempts: 3, deadline: .seconds(5), keepsUnlisted: .zero, jitter: { 1 }, sleep: { _ in try Task.checkCancellation() }
    )

    private func mirror(in directory: URL) throws -> PRMirror {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = PRDiskFileStore(directory: directory)
        return PRMirror(files: files, client: client, shown: PRMirror.savedRows(in: files), policy: Self.quick)
    }

    /// A Mac's app group folder is under `Library/Group Containers`: a space in the path hides no file.
    @Test func aMirrorInAFolderWithASpaceShowsItsRowsAndDownloadsThemOnce() async throws {
        let rows = [row(1)]
        await worker.set(list: rows)
        let directory = storage.directory
            .appending(path: "Group Containers/pr-viewer", directoryHint: .isDirectory)
        let mirror = try mirror(in: directory)
        _ = await mirror.begin(rows, generation: 1)
        let first = await mirror.sync(generation: 1)
        #expect(first?.rows.map(\.id) == rows.map(\.id))
        #expect(first?.isComplete == true)
        #expect(PRMirror.savedRows(in: PRDiskFileStore(directory: directory)).map(\.id) == rows.map(\.id))
        _ = await mirror.begin(rows, generation: 2)
        _ = await mirror.sync(generation: 2)
        #expect(await worker.count("/diff") == 1, "the second sync found the file on disk")
    }

    /// The kept reads are a folder of `ReadStore`'s inside the mirror's: prune spares it whole.
    @Test func pruneKeepsTheKeptReadsAndRemovesAnOldFile() async throws {
        let rows = [row(1)]
        await worker.set(list: rows)
        let directory = storage.directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mirror = try mirror(in: directory)
        let kept = directory.appending(path: PRMirror.keptFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: kept.appending(path: "merged-mine.json"))
        try Data("old".utf8).write(to: directory.appending(path: "old-revision.diff"))
        _ = await mirror.begin(rows, generation: 1)
        _ = await mirror.sync(generation: 1)
        let keptFile = kept.appending(path: "merged-mine.json").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: keptFile))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "old-revision.diff").path(percentEncoded: false)
        ), "this sync did prune")
    }
}
