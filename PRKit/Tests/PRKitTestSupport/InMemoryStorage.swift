import DurableNetworking
import Foundation
import PRKit
import PRKitCore
import Synchronization

/// A folder of files in memory. A write's time is the store's `now`, which a test sets.
public final class InMemoryFileStore: PRFileStore {
    private let state = Mutex<(files: [String: (data: Data, modified: Date)], now: Date)>(
        ([:], Date(timeIntervalSince1970: 0))
    )

    public init() {}

    /// What a write from now on records as its time.
    public var now: Date {
        get { state.withLock { $0.now } }
        set { state.withLock { $0.now = newValue } }
    }

    public func read(_ name: String) -> Data? {
        state.withLock { $0.files[name]?.data }
    }

    public func write(_ data: Data, to name: String) throws {
        state.withLock { $0.files[name] = (data, $0.now) }
    }

    public func remove(_ name: String) {
        state.withLock { $0.files[name] = nil }
    }

    public func exists(_ name: String) -> Bool {
        state.withLock { $0.files[name] != nil }
    }

    public func names() -> [String] {
        state.withLock { Array($0.files.keys) }
    }

    public func modified(_ name: String) -> Date? {
        state.withLock { $0.files[name]?.modified }
    }
}

/// Last good answers in memory.
public final class InMemoryKeptStore: PRKeptStore {
    private let answers = Mutex<[String: KeptAnswer]>([:])

    public init() {}

    public func load(_ key: InboxKey) -> KeptAnswer? {
        answers.withLock { $0[key.description] }
    }

    public func save(_ answer: KeptAnswer, for key: InboxKey) throws {
        answers.withLock { $0[key.description] = answer }
    }
}

/// Settings in memory, read back as `UserDefaults` would read what was set.
public final class InMemoryKeyValueStore: PRKeyValueStore {
    private var values: [String: Any] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    public func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    public func object(forKey key: String) -> Any? {
        values[key]
    }

    public func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    public func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    public func removeObject(forKey key: String) {
        values[key] = nil
    }
}

public extension PRKitStorage {
    /// Every store in memory: nothing touches the disk or the preferences.
    static func inMemory(
        mirror: InMemoryFileStore = InMemoryFileStore(), settings: InMemoryKeyValueStore = InMemoryKeyValueStore()
    ) -> PRKitStorage {
        PRKitStorage(mirror: mirror, kept: InMemoryKeptStore(), drafts: InMemoryFileStore(), settings: settings)
    }
}
