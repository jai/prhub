import DurableNetworking
import Foundation
@testable import PRKit
import Testing

/// Any request reaching a transport in an offline/sample test is an unintended boundary crossing.
struct UnexpectedTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        Issue.record("Unexpected transport request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        throw URLError(.unsupportedURL)
    }
}

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

/// Waits for an observable state, failing the test instead of hanging or proceeding after a blind delay.
@MainActor
func waitUntil(
    _ message: String, timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(ContinuousClock.now < deadline, Comment(rawValue: message), sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(5))
    }
}
