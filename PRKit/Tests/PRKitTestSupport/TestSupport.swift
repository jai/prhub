import DurableNetworking
import Foundation
import Synchronization
import Testing

/// Any request reaching a transport in an offline/sample test is an unintended boundary crossing.
public struct UnexpectedTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        Issue.record("Unexpected transport request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        throw URLError(.unsupportedURL)
    }
}

/// Waits for a state that other tasks are on their way to, by giving way to them, and fails the test instead of
/// hanging if they never get there. Gives way a bounded number of times and never reads the time, so a unit test can
/// use it.
@MainActor
public func settle(
    _ message: String, yields: Int = 100_000, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    for _ in 0 ..< yields {
        if condition() {
            return
        }
        await Task.yield()
    }
    try #require(condition(), Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// A clock that stands still until a test moves it: a sleep on it ends when `advance` passes its deadline, or when it
/// is cancelled. Its instants are `ContinuousClock`'s, so it stands in wherever the code reads that clock's `now`.
public final class TestClock: Clock {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: ContinuousClock.Instant, sleepers: [UUID: Sleeper])>((.now, [:]))
    public let minimumResolution = Duration.zero

    public init() {}

    public var now: ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    /// How many sleeps are waiting on the clock.
    public var sleepers: Int {
        state.withLock { $0.sleepers.count }
    }

    public func sleep(until deadline: ContinuousClock.Instant, tolerance _: Duration? = nil) async throws {
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
    public func advance(by duration: Duration) {
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
    public func advance(
        by duration: Duration, afterSleepers count: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await settle("\(count) sleeping on the test clock", sourceLocation: sourceLocation) { sleepers >= count }
        advance(by: duration)
    }
}
