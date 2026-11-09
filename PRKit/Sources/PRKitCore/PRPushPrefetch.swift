import Foundation
import PRKitNetwork
import os

/// Where the PR mirror keeps its files (`PRMirror`): in the app group's container when the host names one, so its
/// Notification Service Extension writes where the app reads, else in the caches.
public enum PRMirrorLocation {
    /// The mirror's folder name, as it always was in the caches.
    public static let folderName = "pr-viewer"

    private static let logger = Logger(subsystem: "PRKit", category: "mirror")
    /// The groups already said to have no container: each is said once.
    private static let groupsWithoutContainer = OSAllocatedUnfairLock(initialState: Set<String>())

    /// `Library/Caches/pr-viewer` in the app group's container, or in the app's own caches without a group. A group
    /// with no container (a build without the entitlement) is said once in the system log, and the caches are used.
    public static func directory(
        appGroup: String?,
        container: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> URL {
        let groupCaches = appGroup.flatMap { group -> URL? in
            guard let url = container(group) else {
                if isFirstMiss(of: group) {
                    logger.error("PR mirror: app group \(group, privacy: .public) has no container; using the caches")
                }
                return nil
            }
            return url.appending(path: "Library/Caches", directoryHint: .isDirectory)
        }
        return (groupCaches ?? URL.cachesDirectory).appending(path: folderName, directoryHint: .isDirectory)
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
    let directory: URL

    public init(client: PRViewerClient, directory: URL) {
        self.client = client
        self.directory = directory
    }

    public func prefetch(_ row: PullRequestRow?, deadline: Duration) async -> Outcome {
        guard let row else {
            return .noRow
        }
        guard client.access.baseURL() != nil else {
            return .notPaired
        }
        if isLocal(row) {
            return .alreadyLocal
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try await withDeadline(deadline) { try await download(row) }
        } catch is DeadlineExceeded {
            return .timedOut
        } catch {
            return .failed
        }
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
            try detailData.write(to: directory.appending(path: row.detailFileName), options: .atomic)
        }
        if let diffData {
            guard !diffData.isEmpty else {
                return .failed
            }
            try diffData.write(to: directory.appending(path: row.diffFileName), options: .atomic)
        }
        if let lines = await keyLines, let name = row.keyLinesFileName, Self.isObject(lines) {
            try? lines.write(to: directory.appending(path: name), options: .atomic)
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
        FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
    }

    /// A stored detail and key lines are JSON objects; anything else is not written, and the tap reads the PR itself.
    private static func isObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
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
    let file: URL

    public init(directory: URL) {
        file = directory.appending(path: Self.fileName)
    }

    public func append(_ entry: Entry) {
        let entries = (read() + [entry]).suffix(Self.kept)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(Array(entries)).write(to: file, options: .atomic)
    }

    /// Every entry kept, and none after.
    public func drain() -> [Entry] {
        let entries = read()
        try? FileManager.default.removeItem(at: file)
        return entries
    }

    private func read() -> [Entry] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
}
