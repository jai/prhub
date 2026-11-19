import DurableNetworking
import Foundation

/// A folder of named files: the PR mirror's (`PRMirror`), the drafts' (`PRDraftStore`). On the phone it is
/// `PRDiskFileStore`; a unit test passes one in memory.
public protocol PRFileStore: Sendable {
    /// Nil when there is no such file, or it can't be read.
    func read(_ name: String) -> Data?
    /// The whole file or nothing: a write that fails leaves the file as it was.
    func write(_ data: Data, to name: String) throws
    func remove(_ name: String)
    func exists(_ name: String) -> Bool
    /// Every name in the folder, folders among them.
    func names() -> [String]
    /// When the file was last written; nil when there is no such file.
    func modified(_ name: String) -> Date?
}

public extension PRFileStore {
    /// Every file and folder, gone.
    func removeAll() {
        for name in names() {
            remove(name)
        }
    }
}

/// Files in a folder on disk, made if it is not there; each write atomic.
public struct PRDiskFileStore: PRFileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL {
        directory.appending(path: name)
    }

    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: url(name), options: .mappedIfSafe)
    }

    public func write(_ data: Data, to name: String) throws {
        try data.write(to: url(name), options: .atomic)
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path(percentEncoded: false))
    }

    public func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    public func modified(_ name: String) -> Date? {
        (try? url(name).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Settings the PR screens' model keeps: `UserDefaults` on the phone; a unit test passes one in memory. The members are
/// `UserDefaults`' own. SwiftUI's `@AppStorage` in views reads `UserDefaults` itself.
public protocol PRKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PRKeyValueStore {}

/// Last good answers to reads, one per key (DurableNetworking's `ReadStore` on the phone); a unit test passes one in
/// memory.
public protocol PRKeptStore: Sendable {
    func load(_ key: InboxKey) -> KeptAnswer?
    func save(_ answer: KeptAnswer, for key: InboxKey) throws
}

extension ReadStore: PRKeptStore {}
