import Foundation
import PRKitCore
import Synchronization
import Testing

/// The Worker's answers a PR's files are read from, for a test to put in a scripted Worker's mouth.
public enum PRTestPayload {
    /// A PR's detail with nothing on it but what a test names. A file is marked viewed only on a PR with an `id`.
    public static func detail(
        id: String? = nil, head: String = "h", title: String? = nil, additions: Int = 0, deletions: Int = 0,
        changedFiles: Int = 0
    ) -> String {
        let title = title.map { "\"\($0)\"" } ?? "null"
        let id = id.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {\(id)"url":"u","head":"\(head)","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"",
        "additions":\(additions),"deletions":\(deletions),"changedFiles":\(changedFiles),"reviewDecision":null,
        "mergeState":"CLEAN","labels":[],"checks":[],"comments":{"nodes":[]},"reviews":{"nodes":[]},
        "reviewThreads":{"nodes":[]},"title":\(title)}
        """
    }
}

/// A pr-worker as the mirror's queue (`PRMirror`) meets it: its list, and each PR's files when a gated request is let
/// go. Each request's path is recorded, without its query.
public actor PRMirrorWorker {
    public private(set) var list: [PullRequestRow] = []
    private var holdAll = false
    public private(set) var requests: [String] = []
    private var gated: Set<String> = []
    private var heldAfterCancellation: Set<String> = []
    /// Statuses to answer a path with, one per request, before it answers 200.
    private var statuses: [String: [Int]] = [:]
    private var bodies: [String: Data] = [:]
    private var gates: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func set(list: [PullRequestRow]) {
        self.list = list
    }

    public func gateAll() {
        holdAll = true
    }

    public func openAll() {
        holdAll = false
        for path in Array(gates.keys) {
            open(path)
        }
    }

    public func answer(_ path: String, statuses: [Int] = [], body: String? = nil) {
        self.statuses[path] = statuses
        bodies[path] = body.map { Data($0.utf8) }
    }

    public func gate(_ path: String, holdsAfterCancellation: Bool = false) {
        gated.insert(path)
        if holdsAfterCancellation {
            heldAfterCancellation.insert(path)
        }
    }

    public func open(_ path: String) {
        gated.remove(path)
        heldAfterCancellation.remove(path)
        for waiter in (gates.removeValue(forKey: path) ?? [:]).values {
            waiter.resume()
        }
    }

    /// Gives way until `path` is asked for, and fails the test instead of hanging if it never is. Reads no clock.
    public func waitForRequest(
        _ path: String, yields: Int = 100_000, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitFor("Expected request \(path)", yields: yields, sourceLocation: sourceLocation) {
            $0.requests.contains(path)
        }
    }

    /// Gives way until `count` requests have come, as `waitForRequest`.
    public func waitForRequests(
        _ count: Int, yields: Int = 100_000, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitFor("Expected \(count) requests", yields: yields, sourceLocation: sourceLocation) {
            $0.requests.count >= count
        }
    }

    private func waitFor(
        _ message: String, yields: Int, sourceLocation: SourceLocation, _ condition: (isolated PRMirrorWorker) -> Bool
    ) async throws {
        for _ in 0 ..< yields {
            if condition(self) {
                return
            }
            await Task.yield()
        }
        let met = condition(self)
        try #require(met, Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    private func cancelledGate(_ path: String, id: UUID) {
        gates[path]?.removeValue(forKey: id)?.resume()
    }

    private func waitAtGate(_ path: String) async throws {
        if heldAfterCancellation.contains(path) {
            await withCheckedContinuation { continuation in
                gates[path, default: [:]][UUID()] = continuation
            }
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    gates[path, default: [:]][id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelledGate(path, id: id) }
        }
        try Task.checkCancellation()
    }

    /// How many requests' paths end in `suffix`.
    public func count(_ suffix: String) -> Int {
        requests.filter { $0.hasSuffix(suffix) }.count
    }

    public func answer(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path() ?? ""
        requests.append(path)
        let body: Data
        if path == "/prs" {
            body = try JSONSerialization.data(withJSONObject: [
                "prs": JSONSerialization.jsonObject(with: JSONEncoder().encode(list)), "synced_at": 0,
            ])
        } else {
            if gated.contains(path) || holdAll {
                try await waitAtGate(path)
            }
            body = bodies[path] ?? Data(path.hasSuffix("/detail") ? PRTestPayload.detail().utf8 : "diff --git a/f b/f\n".utf8)
        }
        let status = statuses[path]?.isEmpty == false ? statuses[path]!.removeFirst() : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// A pr-worker as an alert's prefetch and open meet it (`PRPushPrefetch`, `PRsModel.session`): it answers every file,
/// records each request with its query, and holds any whose path is gated until its request is cancelled.
public final class PRAlertWorker: Sendable {
    private struct State {
        var requests: [String] = []
        var gated: Set<String> = []
        var detail = PRAlertWorker.detail
        var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    /// The detail it answers until `answer(detail:)`.
    public static let detail = PRTestPayload.detail(title: "T")

    private let state = Mutex(State())

    public init() {}

    public var requests: [String] {
        state.withLock { $0.requests }
    }

    public func gate(_ path: String) {
        state.withLock { _ = $0.gated.insert(path) }
    }

    public func answer(detail: String) {
        state.withLock { $0.detail = detail }
    }

    public func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let path = url.path()
        let (isGated, detail) = state.withLock { state in
            // The query's items in order, so a test names one request one way.
            let query = (url.query() ?? "").split(separator: "&").sorted().joined(separator: "&")
            state.requests.append(query.isEmpty ? path : "\(path)?\(query)")
            return (state.gated.contains(path), state.detail)
        }
        if isGated {
            try await waitAtGate()
        }
        let body = path.hasSuffix("/detail") ? detail : path.hasSuffix("/key-lines") ? "{\"items\":[]}" : "diff --git a/f b/f\n"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// A gated request never answers: it ends when its task is cancelled.
    private func waitAtGate() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let isHeld = state.withLock { state in
                    guard !Task.isCancelled else {
                        return false
                    }
                    state.held[id] = continuation
                    return true
                }
                if !isHeld {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.held.removeValue(forKey: id) }?.resume()
        }
        throw CancellationError()
    }
}
