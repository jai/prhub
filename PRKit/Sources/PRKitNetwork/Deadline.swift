import Foundation
import Synchronization

package struct DeadlineExceeded: Error, Equatable {
    package init() {}
}

/// Runs `operation` and returns its result, or throws `DeadlineExceeded` once `deadline` has passed — whichever comes
/// first. Unlike a task-group race this returns on time even when the operation ignores cancellation, which
/// `HKHealthStore.save` (a completion-handler import) does: a task group would wait for the hung child before
/// returning and the push handler would overrun its 30 s. After a timeout the operation is cancelled and left to
/// finish on its own; whatever it persists later is picked up by the next retry.
package func withDeadline<T: Sendable>(
    _ deadline: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            if race.finish() {
                continuation.resume(with: result)
            }
        }
        race.setTimer(Task {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return // cancelled: the operation finished first
            }
            if race.finish() {
                work.cancel()
                continuation.resume(throwing: DeadlineExceeded())
            }
        })
    }
}

/// First caller of `finish()` wins the right to resume the continuation; the timer is cancelled with it.
private final class DeadlineRace: Sendable {
    private struct State {
        var finished = false
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func finish() -> Bool {
        state.withLock { state in
            guard !state.finished else {
                return false
            }
            state.finished = true
            state.timer?.cancel()
            state.timer = nil
            return true
        }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        state.withLock { state in
            if state.finished {
                timer.cancel()
            } else {
                state.timer = timer
            }
        }
    }
}
