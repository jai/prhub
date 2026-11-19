import Foundation
@testable import PRKitCore
import Testing

/// Where the mirror lives (`PRMirrorLocation`): a mirror left in an earlier build's caches moves to Application Support
/// once, on disk. `PRKitUnitTests`' suite of this name checks which folders it picks.
struct PRMirrorLocationTests {
    private let storage = TestStorage()
    private var root: URL {
        storage.directory
    }

    private var own: PRMirrorLocation.Library {
        PRMirrorLocation.Library(
            caches: root.appending(path: "own/Caches"), support: root.appending(path: "own/Application Support")
        )
    }

    @Test func aMirrorInTheGroupsCachesMovesOnceAndIsLeftOutOfBackups() throws {
        let container = root.appending(path: "Group Containers/g", directoryHint: .isDirectory)
        let old = container.appending(path: "Library/Caches/pr-viewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appending(path: "rows.json"))

        let directory = PRMirrorLocation.directory(appGroup: "g", container: { _ in container }, own: own)

        let rows = directory.appending(path: "rows.json").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: rows))
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func aMirrorInTheAppsOwnCachesMovesToTheGroup() throws {
        let container = root.appending(path: "Group Containers/g", directoryHint: .isDirectory)
        let old = own.caches.appending(path: "pr-viewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appending(path: "rows.json"))

        let directory = PRMirrorLocation.directory(appGroup: "g", container: { _ in container }, own: own)

        let rows = directory.appending(path: "rows.json").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: rows))
    }

    @Test func aKeptMirrorIsNotReplacedByAnOldOne() throws {
        let kept = own.support.appending(path: "pr-viewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: kept.appending(path: "rows.json"))
        let old = own.caches.appending(path: "pr-viewer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "rows.json"))

        let directory = PRMirrorLocation.directory(appGroup: nil, own: own)

        #expect(try Data(contentsOf: directory.appending(path: "rows.json")) == Data("new".utf8))
    }
}
