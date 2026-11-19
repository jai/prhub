import DurableNetworking
import Foundation
@testable import PRKit
import Synchronization
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

/// A clock that stands still until a test moves it: a sleep on it ends when `advance` passes its deadline, or when it
/// is cancelled. Its instants are `ContinuousClock`'s, so it stands in wherever the code reads that clock's `now`.
final class TestClock: Clock {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: ContinuousClock.Instant, sleepers: [UUID: Sleeper])>((.now, [:]))
    let minimumResolution = Duration.zero

    var now: ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    /// How many sleeps are waiting on the clock.
    var sleepers: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance _: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let ended: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if deadline <= state.now {
                        return .success(())
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, wake: wake)
                    return nil
                }
                if let ended {
                    wake.resume(with: ended)
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.wake.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration`, ending every sleep whose deadline it reaches.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now += duration
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys {
                state.sleepers[id] = nil
            }
            return due.values.map(\.wake)
        }
        for wake in due {
            wake.resume()
        }
    }

    /// Moves the clock on once `count` sleeps wait on it, so one that has not started yet is not left behind.
    @MainActor
    func advance(
        by duration: Duration, afterSleepers count: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("\(count) sleeping on the test clock", sourceLocation: sourceLocation) { sleepers >= count }
        advance(by: duration)
    }
}
