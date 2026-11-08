import PRKitNetwork
import PRKitCore
import PRKitDesign
import Foundation

/// Keeps the phone a complete copy of the Worker's list, and is the one owner of its files: every download, publish
/// and prune happens here, so two syncs can't race.
///
/// - A PR is a set: a row shows a revision only once its description and diff for that revision are both on disk;
///   until then the last complete revision stays (files are named by revision). A tap never meets a half-synced PR.
/// - A list is published from what is on disk at once (`begin`); its PRs' files download behind it (`sync`).
/// - Each file downloads once however many syncs want it: a second request waits for the one in flight. At most
///   `parallelDownloads` files download at a time, across every sync.
/// - Every payload is checked before it is written, and written atomically: a bad one never lands.
/// - A file that fails for a passing reason (offline, a timeout, a 5xx, a bad payload, a full disk) is tried again with
///   a growing, jittered wait, up to `RetryPolicy.attempts` times; one GitHub won't serve (404, 406, 410, 413, 422) is
///   not. Then its PR is marked as not brought up to date and keeps its last good revision until a pull tries again.
///   One failing PR holds up no other.
/// - The newest list wins: each list has a generation, and only the newest one's rows are published. A download that
///   only an older list wanted is cancelled; a cancelled download writes nothing and is no failure.
/// - Prune runs after publishing the newest list, and keeps what that list and the shown rows name and every file
///   still downloading.
actor PRMirror {
    static let parallelDownloads = 6
    static let rowsFile = "rows.json"

    struct RetryPolicy: Sendable {
        var first: Duration = .seconds(2)
        var longest: Duration = .seconds(300)
        var attempts = 5
        /// How long a wake waits for downloads before it publishes what it has.
        var deadline: Duration = .seconds(20)
        /// How long prune leaves a file no list names, such as an alert's PR fetched before the list named it: longer
        /// than an alert waits to be tapped and synced.
        var keepsUnlisted: Duration = .seconds(30 * 60)
    }

    nonisolated let directory: URL
    nonisolated let client: PRViewerClient
    let policy: RetryPolicy
    /// Where a disk error or a download that failed for good is said: the host's event log, set at any time.
    nonisolated let log = LogSink()

    struct Result: Sendable {
        let rows: [PullRequestRow]
        /// The PRs whose content arrived in this pass.
        let fetched: [String]
        let isComplete: Bool
        /// The PRs whose files failed for good, by row id: each keeps its last good revision.
        let failed: Set<String>
    }

    /// The newest list and its generation: what is published.
    private var generation = 0
    private var latest: [PullRequestRow] = []
    /// The rows last published, which a row whose new files are not here yet keeps showing.
    private var shown: [PullRequestRow]
    /// Downloads by file name; a request for a file already here waits for this one.
    var inFlight: [String: Download] = [:]
    /// Downloads cancelled but not yet ended: prune leaves their files alone.
    var ending: [UUID: String] = [:]
    /// Files that failed for good, until a pull tries again.
    var failedFiles: Set<String> = []
    /// Files waiting to try again: a pull starts them afresh, at once.
    var backingOff: Set<String> = []
    var running = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
    /// Hears the newest list's rows, and the PRs that failed, each time a PR's files land.
    private var landed: (@Sendable (Int, [PullRequestRow], Set<String>) async -> Void)?
    /// The most files that were downloading at once: for a test.
    var mostAtOnce = 0

    struct Download {
        let id: UUID
        let task: Task<Outcome, Never>
    }

    enum Outcome: Sendable {
        case landed, failed, cancelled
    }

    init(
        directory: URL, client: PRViewerClient, shown: [PullRequestRow] = [], policy: RetryPolicy = RetryPolicy()
    ) {
        self.directory = directory
        self.client = client
        self.shown = shown
        self.policy = policy
    }

    /// The rows the last launch saved, those whose files are all still here: one that lost a file (a crash, or iOS
    /// clearing the cache) is downloaded again at the next sync.
    static func savedRows(in directory: URL) -> [PullRequestRow] {
        let saved = try? Data(contentsOf: directory.appending(path: rowsFile))
        let rows = saved.flatMap { try? JSONDecoder().decode([PullRequestRow].self, from: $0) } ?? []
        return rows.filter { isLocal($0, in: directory) }
    }

    /// The rows to show. A row whose files are not all here keeps the version that was, or waits if there was none.
    static func publishable(
        _ latest: [PullRequestRow], previous: [PullRequestRow], isLocal: (PullRequestRow) -> Bool
    ) -> [PullRequestRow] {
        let shown = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return latest.compactMap { row in
            if isLocal(row) {
                return row
            }
            return shown[row.id].flatMap { isLocal($0) ? $0 : nil }
        }
    }

    /// A row's set: its description and its diff. Key lines are not part of it: a PR opens without them, and the screen
    /// asks for them itself.
    nonisolated func isLocal(_ row: PullRequestRow) -> Bool {
        Self.isLocal(row, in: directory)
    }

    private static func isLocal(_ row: PullRequestRow, in directory: URL) -> Bool {
        let exists = { (name: String) in
            FileManager.default.fileExists(atPath: directory.appending(path: name).path())
        }
        return exists(row.detailFileName) && (!row.hasDiff || exists(row.diffFileName))
    }

    /// A new list, as generation `generation`: what can show now, from files already here, saved as the list the next
    /// launch starts from. Nothing is downloaded and nothing deleted. `retry` (a pull) tries every failed file again,
    /// at once. Nil for a list older than one already begun.
    func begin(_ list: [PullRequestRow], generation: Int, retry: Bool = false) -> [PullRequestRow]? {
        guard generation > self.generation else {
            return nil
        }
        self.generation = generation
        latest = list
        if retry {
            failedFiles = []
        }
        let wanted = Set(list.flatMap(\.files))
        // A download no longer wanted goes; so, on a pull, does one waiting to try again, which starts afresh.
        for (name, download) in inFlight where !wanted.contains(name) || (retry && backingOff.contains(name)) {
            download.task.cancel()
            ending[download.id] = name
            inFlight[name] = nil
        }
        return publish()
    }

    /// Everything a wake has time for, for generation `generation`: what finished stays on disk, and the next sync
    /// carries on from there. `landed` hears the rows each time a PR's files arrive. Nil once a newer list has begun:
    /// that one publishes.
    func sync(
        generation: Int,
        landed: @escaping @Sendable (Int, [PullRequestRow], Set<String>) async -> Void = { _, _, _ in }
    ) async -> Result? {
        guard generation == self.generation else {
            return nil
        }
        self.landed = landed
        let list = latest
        let missing = list.filter { !isLocal($0) || $0.keyLinesFileName.map { !fileExists($0) } == true }
        let fetched = Fetched()
        try? await withDeadline(policy.deadline) {
            await self.fetch(missing, into: fetched, generation: generation)
        }
        guard generation == self.generation else {
            return nil
        }
        let published = publish()
        prune()
        return Result(
            rows: published, fetched: await fetched.ids,
            isComplete: published.count == list.count && list.allSatisfy(isLocal), failed: failedRows()
        )
    }

    /// PRHub's Disconnect: nothing downloading, nothing shown, no file left.
    func forget(generation: Int) {
        self.generation = max(self.generation, generation)
        latest = []
        shown = []
        failedFiles = []
        for (name, download) in inFlight {
            download.task.cancel()
            ending[download.id] = name
        }
        inFlight = [:]
        let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The newest list's PRs whose files failed for good.
    private func failedRows() -> Set<String> {
        Set(latest.filter { row in row.requiredFiles.contains { failedFiles.contains($0) } }.map(\.id))
    }

    /// `rows.json` names only rows whose files are all here.
    private func publish() -> [PullRequestRow] {
        shown = Self.publishable(latest, previous: shown, isLocal: isLocal)
        do {
            try JSONEncoder().encode(shown).write(to: directory.appending(path: Self.rowsFile), options: .atomic)
        } catch {
            log.say("PR mirror: rows not saved: \(error.localizedDescription)")
        }
        return shown
    }

    /// Each PR's files, the PRs side by side; each file through the queue.
    private func fetch(_ rows: [PullRequestRow], into fetched: Fetched, generation: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask {
                    if await self.download(row, generation: generation) {
                        await fetched.add(row.id)
                        await self.rowLanded(generation: generation)
                    }
                }
            }
        }
    }

    /// The diff and the description, side by side; then key lines, which a PR does without.
    private func download(_ row: PullRequestRow, generation: Int) async -> Bool {
        async let diff = row.hasDiff && !fileExists(row.diffFileName)
            ? file(row.diffFileName, check: { !$0.isEmpty }, read: { try await self.client.diff(row) }) : .landed
        async let detail = !fileExists(row.detailFileName)
            ? file(row.detailFileName, check: { (try? PullRequestDetail.decode($0)) != nil }, read: {
                try await self.client.detail(row)
            }) : .landed
        let whole = await (diff, detail) == (.landed, .landed)
        if whole, let name = row.keyLinesFileName, let context = row.keyLines, !fileExists(name) {
            _ = await file(
                name, check: { (try? JSONDecoder().decode(PRKeyLines.self, from: $0)) != nil },
                read: { try await self.client.keyLines(row, context: context) }
            )
        }
        if !whole {
            await rowLanded(generation: generation) // its failure, for the row to say so
        }
        return whole
    }

    private func rowLanded(generation: Int) async {
        guard generation == self.generation, let landed else {
            return
        }
        let rows = publish()
        await landed(generation, rows, failedRows())
    }

    /// Keeps what the newest list and the shown rows name, every file still downloading, and any file younger than
    /// `keepsUnlisted`: an alert's PR that the Notification Service Extension fetched (`PRPushPrefetch`) before the list
    /// named it. Anything else — a file of an old revision, a temporary file left by a crash — goes.
    private func prune() {
        let wanted = Set((latest + shown).flatMap(\.files))
            .union(inFlight.keys).union(ending.values).union([Self.rowsFile, PRPushPrefetchLog.fileName])
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        for file in files where !wanted.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            if Date.now.timeIntervalSince(modified) >= Double(policy.keepsUnlisted.components.seconds) {
                try? manager.removeItem(at: file)
            }
        }
    }

    nonisolated func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path())
    }
}
