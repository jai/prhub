import Foundation
@testable import PRKit
import Testing

/// Only this test's temporary tree is removed. Mirrors and authored drafts have separate children.
final class TestStorage {
    private let root = URL.temporaryDirectory.appending(path: "prkit-integration-\(UUID().uuidString)")
    private let preferences = TestPreferences()

    var directory: URL {
        root.appending(path: "mirror", directoryHint: .isDirectory)
    }

    var draftDirectory: URL {
        root.appending(path: "drafts", directoryHint: .isDirectory)
    }

    var defaults: UserDefaults {
        preferences.defaults
    }

    init() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Issue.record(error, "Creating owned test directory")
        }
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record(error, "Removing owned test directory")
        }
    }
}

/// An isolated preferences domain, removed when its test finishes.
final class TestPreferences {
    private let name = "prkit-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
