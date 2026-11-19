import DurableNetworking
import Foundation
import os

/// Where the PR mirror keeps its files (`PRMirror`): in the app group's container when the host names one, so its
/// Notification Service Extension writes where the app reads, else in the app's own. In Application Support, which
/// iOS keeps, not the caches, which it may empty when storage runs low: the mirror is what the app shows offline.
public enum PRMirrorLocation {
    /// The mirror's folder name, as it always was in the caches.
    public static let folderName = "pr-viewer"

    private static let logger = Logger(subsystem: "PRKit", category: "mirror")
    /// The groups already said to have no container: each is said once.
    private static let groupsWithoutContainer = OSAllocatedUnfairLock(initialState: Set<String>())

    /// `Library/Application Support/pr-viewer` in the app group's container, or in the app's own without a group. A
    /// group with no container (a build without the entitlement) is said once in the system log, and the app's own is
    /// used. A mirror still in a caches folder from an earlier build is moved here the first time, so nothing is
    /// downloaded again; the folder is left out of backups, as a copy of GitHub.
    public static func directory(
        appGroup: String?,
        container: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
        own: Library = .app
    ) -> URL {
        let library = library(appGroup: appGroup, container: container, own: own)
        let kept = library.support.appending(path: folderName, directoryHint: .isDirectory)
        moveFromCaches([library.caches, own.caches], to: kept)
        return kept
    }

    /// The folders `directory` uses, touching none of them: the app group's container's when it has one, else `own`.
    static func library(appGroup: String?, container: (String) -> URL?, own: Library) -> Library {
        let group = appGroup.flatMap { group -> URL? in
            guard let url = container(group) else {
                if isFirstMiss(of: group) {
                    logger.error("PR mirror: app group \(group, privacy: .public) has no container; using the app's")
                }
                return nil
            }
            return url.appending(path: "Library", directoryHint: .isDirectory)
        }
        return group.map {
            Library(caches: $0.appending(path: "Caches"), support: $0.appending(path: "Application Support"))
        } ?? own
    }

    /// A caches folder and the Application Support folder beside it.
    public struct Library: Equatable, Sendable {
        public var caches: URL
        public var support: URL

        public init(caches: URL, support: URL) {
            self.caches = caches
            self.support = support
        }

        public static var app: Library {
            Library(caches: .cachesDirectory, support: .applicationSupportDirectory)
        }
    }

    /// The first old mirror found is moved to `kept`, unless `kept` is there already. A move that loses to another
    /// process (the app and its extension) changes nothing.
    static func moveFromCaches(_ cachesFolders: [URL], to kept: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: kept.path(percentEncoded: false)) {
            try? manager.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = cachesFolders.map { $0.appending(path: folderName, directoryHint: .isDirectory) }
                .first { manager.fileExists(atPath: $0.path(percentEncoded: false)) }
            if let old {
                try? manager.moveItem(at: old, to: kept)
            }
        }
        try? manager.createDirectory(at: kept, withIntermediateDirectories: true)
        var folder = kept
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// True the first time `group` is found to have no container.
    static func isFirstMiss(of group: String) -> Bool {
        groupsWithoutContainer.withLock { $0.insert(group).inserted }
    }
}

/// An alert's PR fetched into the mirror before anyone taps it (docs/api.md, "Alerts"): its stored detail and diff,
/// and key lines when they are ready, side by side, each checked and written whole. It never throws and gives up at
/// `deadline`, so a Notification Service Extension shows its alert either way. The mirror's own sync later finds the
/// files and downloads nothing.
public struct PRPushPrefetch: Sendable {
    /// How a prefetch ended: the values of the app's `push_prefetch` event.
    public enum Outcome: String, CaseIterable, Codable, Sendable {
        /// The detail and diff are now on the phone.
        case landed
        /// They already were.
        case alreadyLocal = "already_local"
        /// The push carried no row.
        case noRow = "no_row"
        /// The phone has no Worker to ask.
        case notPaired = "not_paired"
        case timedOut = "timed_out"
        case failed
    }

    let client: PRViewerClient
    let files: any PRFileStore

    public init(client: PRViewerClient, files: any PRFileStore) {
        self.client = client
        self.files = files
    }

    public init(client: PRViewerClient, directory: URL) {
        self.init(client: client, files: PRDiskFileStore(directory: directory))
    }

    public func prefetch(_ row: PullRequestRow?, deadline: Duration) async -> Outcome {
        guard let row else {
            return .noRow
        }
        guard client.access.baseURL() != nil else {
            return .notPaired
        }
        if isLocal(row) {
            PRAlertedFiles(store: files).note(Self.files(of: row))
            return .alreadyLocal
        }
        do {
            let outcome = try await withDeadline(deadline) { try await download(row) }
            if outcome == .landed {
                PRAlertedFiles(store: files).note(Self.files(of: row))
            }
            return outcome
        } catch is DeadlineExceeded {
            return .timedOut
        } catch {
            return .failed
        }
    }

    /// Every file of the row the mirror may hold: its description, its diff and its key lines.
    static func files(of row: PullRequestRow) -> [String] {
        [row.detailFileName, row.hasDiff ? row.diffFileName : nil, row.keyLinesFileName].compactMap(\.self)
    }

    /// The row's set as the mirror reads it: its description and, unless GitHub won't give one, its diff.
    public func isLocal(_ row: PullRequestRow) -> Bool {
        exists(row.detailFileName) && (!row.hasDiff || exists(row.diffFileName))
    }

    private func download(_ row: PullRequestRow) async throws -> Outcome {
        async let detail = exists(row.detailFileName) ? nil : client.detail(row)
        async let diff = !row.hasDiff || exists(row.diffFileName) ? nil : client.diff(row)
        async let keyLines = keyLinesIfReady(row)
        let (detailData, diffData) = try await (detail, diff)
        if let detailData {
            guard Self.isObject(detailData) else {
                return .failed
            }
            try files.write(detailData, to: row.detailFileName)
        }
        if let diffData {
            guard !diffData.isEmpty else {
                return .failed
            }
            try files.write(diffData, to: row.diffFileName)
        }
        if let lines = await keyLines, let name = row.keyLinesFileName, Self.isObject(lines) {
            try? files.write(lines, to: name)
        }
        return .landed
    }

    /// Key lines a PR opens without: nil when the row has none ready, they are here already, or the read fails.
    private func keyLinesIfReady(_ row: PullRequestRow) async -> Data? {
        guard let context = row.keyLines, let name = row.keyLinesFileName, !exists(name) else {
            return nil
        }
        return try? await client.keyLines(row, context: context)
    }

    private func exists(_ name: String) -> Bool {
        files.exists(name)
    }

    /// A stored detail and key lines are JSON objects; anything else is not written, and the tap reads the PR itself.
    private static func isObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}

/// The files each alert's prefetch put on the phone, and when. An alert stays in Notification Center long after the
/// mirror would prune the files of a PR on no list (`PRMirror.RetryPolicy.keepsUnlisted`), and a tap on it then waited
/// on the network. The mirror keeps these files for `keptFor`. Written only by the prefetch; the app reads it.
public struct PRAlertedFiles: Sendable {
    public static let fileName = "alerted.json"
    /// How long an alert is likely to be tapped from Notification Center.
    public static let keptFor: TimeInterval = 7 * 24 * 60 * 60
    let store: any PRFileStore

    public init(store: any PRFileStore) {
        self.store = store
    }

    public init(directory: URL) {
        self.init(store: PRDiskFileStore(directory: directory))
    }

    /// `names` alerted at `now`. Entries older than `keptFor` are removed.
    public func note(_ names: [String], at now: Date = .now) {
        var entries = live(at: now)
        for name in names {
            entries[name] = now
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? store.write(data, to: Self.fileName)
        }
    }

    /// The files of alerts that are not older than `keptFor`.
    public func names(at now: Date = .now) -> Set<String> {
        Set(live(at: now).keys)
    }

    private func live(at now: Date) -> [String: Date] {
        let entries = store.read(Self.fileName).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }
        return (entries ?? [:]).filter { now.timeIntervalSince($0.value) < Self.keptFor }
    }
}

/// How each prefetch went, kept in the mirror's folder by the extension until the app sends them as `push_prefetch`
/// events: the extension has no analytics of its own, and the app's Settings switch decides.
public struct PRPushPrefetchLog: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let outcome: PRPushPrefetch.Outcome
        public let milliseconds: Int

        public init(outcome: PRPushPrefetch.Outcome, milliseconds: Int) {
            self.outcome = outcome
            self.milliseconds = milliseconds
        }
    }

    public static let fileName = "push-prefetch.json"
    /// A phone that never opens the app keeps no more than this.
    static let kept = 50
    let store: any PRFileStore

    public init(store: any PRFileStore) {
        self.store = store
    }

    public init(directory: URL) {
        self.init(store: PRDiskFileStore(directory: directory))
    }

    public func append(_ entry: Entry) {
        let entries = (read() + [entry]).suffix(Self.kept)
        if let data = try? JSONEncoder().encode(Array(entries)) {
            try? store.write(data, to: Self.fileName)
        }
    }

    /// Every entry kept, and none after.
    public func drain() -> [Entry] {
        let entries = read()
        store.remove(Self.fileName)
        return entries
    }

    private func read() -> [Entry] {
        store.read(Self.fileName).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
}
