import Foundation
import os
import PRKitCore
import Synchronization

/// The mirror's queue (`PRMirror`): one download per file, a slot each, tried again on a passing failure.
extension PRMirror {
    /// One file, once: the download already in flight for `name`, else a new one. A file that failed for good waits
    /// for a pull.
    func file(
        _ name: String, check: @escaping @Sendable (Data) -> Bool, read: @escaping @Sendable () async throws -> Data?
    ) async -> Outcome {
        if failedFiles.contains(name) {
            return .failed
        }
        if let download = inFlight[name] {
            return await download.task.value
        }
        let id = UUID()
        let task = Task<Outcome, Never> {
            let outcome = await self.attempts(name, check: check, read: read)
            self.ended(id, name: name, outcome: outcome)
            return outcome
        }
        inFlight[name] = Download(id: id, task: task)
        return await task.value
    }

    enum Attempt {
        case written, permanent, passing(String), cancelled
    }

    /// Tries until it lands, fails for good or is cancelled, with a growing, jittered wait between tries.
    func attempts(
        _ name: String, check: @Sendable (Data) -> Bool, read: @Sendable () async throws -> Data?
    ) async -> Outcome {
        var wait = policy.first
        for tries in 1...policy.attempts {
            switch await attempt(name, check: check, read: read) {
            case .written:
                return .landed
            case .cancelled:
                return .cancelled
            case .permanent:
                return .failed
            case let .passing(why):
                guard tries < policy.attempts else {
                    log.say("PR mirror: \(name) not downloaded after \(tries) tries: \(why)")
                    return .failed
                }
                let jitter = Double.random(in: 0.5...1.0)
                backingOff.insert(name)
                defer { backingOff.remove(name) }
                do {
                    try await Task.sleep(for: wait * jitter)
                } catch {
                    return .cancelled
                }
                wait = min(wait * 2, policy.longest)
            }
        }
        return .failed
    }

    /// One try, in a download slot: read, check, then write all at once — or nothing.
    func attempt(
        _ name: String, check: @Sendable (Data) -> Bool, read: @Sendable () async throws -> Data?
    ) async -> Attempt {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else {
            return .cancelled
        }
        let data: Data?
        do {
            data = try await read()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                return .cancelled
            }
            if (error as? PRWorkerError)?.isPermanent == true {
                return .permanent
            }
            return .passing(error.localizedDescription)
        }
        guard !Task.isCancelled else {
            return .cancelled
        }
        // Nil is a Worker job still running (key lines): it is asked again later.
        guard let data, check(data) else {
            return .passing(data == nil ? "not ready" : "a payload that does not read")
        }
        do {
            try data.write(to: directory.appending(path: name), options: .atomic)
            return .written
        } catch {
            log.say("PR mirror: \(name) not written: \(error.localizedDescription)")
            return .passing(error.localizedDescription)
        }
    }

    func ended(_ id: UUID, name: String, outcome: Outcome) {
        ending[id] = nil
        if inFlight[name]?.id == id {
            inFlight[name] = nil
            if outcome == .failed {
                failedFiles.insert(name)
            }
        }
    }

    func acquire() async {
        if running >= Self.parallelDownloads {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        mostAtOnce = max(mostAtOnce, running)
    }

    /// A free slot goes straight to the next download waiting, so `running` never drops below what is downloading.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension PullRequestRow {
    /// The mirror's files for this row.
    var files: [String] {
        [diffFileName, detailFileName, keyLinesFileName].compactMap(\.self)
    }

    /// What the row needs to show: its description and its diff.
    var requiredFiles: [String] {
        hasDiff ? [diffFileName, detailFileName] : [detailFileName]
    }
}

/// Where the mirror's failures are said. The system log always; the host's own log once it has set one.
final class LogSink: Sendable {
    private static let logger = Logger(subsystem: "PRMirror", category: "mirror")
    private let handler = Mutex<(@Sendable (String) -> Void)?>(nil)

    func set(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func say(_ line: String) {
        Self.logger.error("\(line, privacy: .public)")
        handler.withLock { $0 }?(line)
    }
}

actor Fetched {
    private(set) var ids: [String] = []

    func add(_ id: String) {
        ids.append(id)
    }
}
