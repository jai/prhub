import Foundation
import PRKitCore
import Testing

/// The mirror's and the drafts' folder on disk (`PRDiskFileStore`): what `PRFileStore` promises, on a real file system.
struct PRDiskFileStoreTests {
    private let storage = TestStorage()

    /// A folder that is not there yet.
    private var directory: URL {
        storage.directory.appending(path: "store", directoryHint: .isDirectory)
    }

    @Test func theFolderIsMadeAndAWriteReadsBack() throws {
        let store = PRDiskFileStore(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(store.read("a.json") == nil)
        try store.write(Data("one".utf8), to: "a.json")
        #expect(store.read("a.json") == Data("one".utf8))
        try store.write(Data("two".utf8), to: "a.json")
        #expect(PRDiskFileStore(directory: directory).read("a.json") == Data("two".utf8), "another store reads it too")
    }

    /// The write goes to a file beside the old one and replaces it whole, so a folder it can't add to fails the write
    /// and leaves the old file as it was, though the file itself could be written in place.
    @Test func aWriteThatFailsLeavesTheFileAsItWas() throws {
        let store = PRDiskFileStore(directory: directory)
        try store.write(Data("old".utf8), to: "a.diff")
        let path = directory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        #expect(throws: (any Error).self) { try store.write(Data("new".utf8), to: "a.diff") }
        #expect(store.read("a.diff") == Data("old".utf8))
    }

    @Test func aRemovedFileIsGoneAndRemovingNothingIsNoError() throws {
        let store = PRDiskFileStore(directory: directory)
        try store.write(Data("x".utf8), to: "a.diff")
        #expect(store.exists("a.diff"))
        store.remove("a.diff")
        #expect(!store.exists("a.diff"))
        #expect(store.read("a.diff") == nil)
        store.remove("a.diff")
    }

    @Test func namesAreEveryFileAndFolderInIt() throws {
        let store = PRDiskFileStore(directory: directory)
        try store.write(Data("x".utf8), to: "a.diff")
        try store.write(Data("y".utf8), to: "b.json")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "kept", directoryHint: .isDirectory), withIntermediateDirectories: true
        )
        #expect(Set(store.names()) == ["a.diff", "b.json", "kept"])
        #expect(store.exists("kept"))
        store.removeAll()
        #expect(store.names().isEmpty)
    }

    @Test func modifiedIsTheFilesModificationDate() throws {
        let store = PRDiskFileStore(directory: directory)
        #expect(store.modified("a.diff") == nil)
        try store.write(Data("x".utf8), to: "a.diff")
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: then], ofItemAtPath: directory.appending(path: "a.diff").path(percentEncoded: false)
        )
        #expect(store.modified("a.diff") == then)
    }

    @Test func aNameWithASpaceIsOneFile() throws {
        let store = PRDiskFileStore(directory: storage.directory.appending(path: "Group Containers/pr-viewer"))
        try store.write(Data("x".utf8), to: "acme__web__7 r1.diff")
        #expect(store.exists("acme__web__7 r1.diff"))
        #expect(store.names() == ["acme__web__7 r1.diff"])
    }
}
