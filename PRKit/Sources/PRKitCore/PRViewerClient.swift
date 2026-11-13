import Foundation
import PRKitNetwork

public enum PRReviewEvent: String, Sendable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

public enum PRDiffSide: String, Codable, Hashable, Sendable {
    case left = "LEFT"
    case right = "RIGHT"
}

/// Something Jai says on a PR, posted as him: each case carries what GitHub needs for it, and nothing else
/// (`worker/src/write-input.ts`).
public enum PRWrite: Encodable, Sendable {
    case comment(body: String)
    case review(PRReviewEvent, body: String, commit: String, comments: [PRDraftComment])
    case line(path: String, line: Int, side: PRDiffSide, body: String, commit: String)
    case reply(thread: String, body: String)
    case resolve(thread: String, resolved: Bool)
    case viewed(pullRequest: String, path: String, viewed: Bool)
    case updateBranch(commit: String)
    case removeRequest
    /// `task` is the task's words as the phone drew them, so a late copy can't tick another.
    case checkbox(index: Int, checked: Bool, task: String?)
    /// `base` is the description he started from, so a late copy can't undo a newer edit.
    case editBody(String, base: String?)
    case merge(method: String, commit: String)

    /// A draft as GitHub takes it: its id is the phone's own.
    private struct ReviewComment: Encodable {
        let path: String
        let line: Int
        let side: String
        let body: String
    }

    /// The JSON the Worker reads. What a case doesn't set stays out of it.
    private struct Payload: Encodable {
        let kind: String
        var body: String?
        var event: String?
        var commit: String?
        var path: String?
        var line: Int?
        var side: String?
        var thread: String?
        var resolved: Bool?
        var comments: [ReviewComment]?
        var pullRequest: String?
        var viewed: Bool?
        var index: Int?
        var checked: Bool?
        var method: String?
        var task: String?
        var base: String?
    }

    private var payload: Payload {
        switch self {
        case let .comment(body):
            Payload(kind: "comment", body: body)
        case let .review(event, body, commit, comments):
            Payload(
                kind: "review", body: body, event: event.rawValue, commit: commit,
                comments: comments.map {
                    ReviewComment(path: $0.path, line: $0.line, side: $0.side.rawValue, body: $0.body)
                }
            )
        case let .line(path, line, side, body, commit):
            Payload(kind: "line", body: body, commit: commit, path: path, line: line, side: side.rawValue)
        case let .reply(thread, body):
            Payload(kind: "reply", body: body, thread: thread)
        case let .resolve(thread, resolved):
            Payload(kind: "resolve", thread: thread, resolved: resolved)
        case let .viewed(pullRequest, path, viewed):
            Payload(kind: "viewed", path: path, pullRequest: pullRequest, viewed: viewed)
        case let .updateBranch(commit):
            Payload(kind: "update_branch", commit: commit)
        case .removeRequest:
            Payload(kind: "remove_request")
        case let .checkbox(index, checked, task):
            Payload(kind: "checkbox", index: index, checked: checked, task: task)
        case let .editBody(body, base):
            Payload(kind: "edit_body", body: body, base: base)
        case let .merge(method, commit):
            Payload(kind: "merge", commit: commit, method: method)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// Where a `PRViewerClient` sends its requests and the bearer it sends: the host's to give (`PRKitHost`). Agent
/// Pager's: Jai's pr-viewer Worker with the token its Pager Worker hands out. PRHub's: the pr-worker it paired with, from
/// the Keychain, with its own device secret as the bearer (docs/api.md) — and nothing at all before it has
/// paired.
public struct PRViewerAccess: Sendable {
    /// Read per request; `nil` until PRHub has paired.
    public let baseURL: @Sendable () -> URL?
    public let bearer: @Sendable () async throws -> String
    /// After a `401`.
    public let discard: @Sendable () async -> Void

    public init(
        baseURL: @escaping @Sendable () -> URL?, bearer: @escaping @Sendable () async throws -> String,
        discard: @escaping @Sendable () async -> Void
    ) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.discard = discard
    }
}

/// The pr-viewer Worker (`pr-worker/`): Jai's, in a different Cloudflare account from the Pager Worker, or PRHub's own
/// pr-worker, as `PRViewerAccess` says. The transport is the app's own: 15 s a request, and in the app it waits for a
/// network. Nothing here repeats a request: a review or a comment must not land twice.
public struct PRViewerClient: Sendable {
    /// One request, once: the app's `URLSession`, or a test's stand-in.
    private let exchange: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public let access: PRViewerAccess
    /// Where each failed request goes (`reporting`); nil reports nothing.
    private var reporter: PRFailureReporter?

    /// `isInForeground` decides whether a request waits for a network: in the app, while someone is looking at it.
    public init(access: PRViewerAccess, isInForeground: @escaping @Sendable () async -> Bool) {
        self.init(access: access, transport: PRTransport(isInForeground: isInForeground))
    }

    package init(access: PRViewerAccess, transport: PRTransport) {
        self.access = access
        exchange = { request in
            try await transport.session().data(for: PRTransport.preferringHTTP3(request))
        }
    }

    /// Over `exchange` in place of a transport: a test's Worker.
    public init(
        access: PRViewerAccess, exchange: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.access = access
        self.exchange = exchange
    }

    /// This client, with each failed request told to `report`: its area, and its status or why there was none. A
    /// request is one try: a caller that tries again reports again, but each area's kind of failure at most once a
    /// minute (`PRFailureReporter`). Not sent: a phone that isn't paired, a cancelled request, a 2xx.
    public func reporting(
        _ report: @escaping @Sendable (PRRequestArea, PRRequestFailure) -> Void
    ) -> PRViewerClient {
        var client = self
        client.reporter = PRFailureReporter(report: report)
        return client
    }

    /// A failed try of `path`, to the reporter. Callers outside the client (an outbox's own request) report theirs.
    public func reportFailure(path: String, _ failure: PRRequestFailure) {
        reporter?.failed(PRRequestArea(path: path), failure)
    }

    public struct List: Decodable, Sendable {
        public let prs: [PullRequestRow]
        // swiftlint:disable:next identifier_name
        public let synced_at: Double
    }

    public func pullRequests() async throws -> List {
        try decode(List.self, from: await get(path: "prs"), path: "prs")
    }

    public struct Merged: Decodable, Sendable {
        public let prs: [PullRequestRow]
    }

    /// The last 50 merged PRs Jai wrote, or reviewed, newest merge first. Read from GitHub each time: they are kept
    /// nowhere.
    public func mergedPullRequests(reviewed: Bool) async throws -> [PullRequestRow] {
        try decode(
            Merged.self, from: await get(path: "prs/merged", query: reviewed ? ["of": "reviewed"] : [:]),
            path: "prs/merged"
        ).prs
    }

    public func diff(_ row: PullRequestRow) async throws -> Data {
        try await get(path: "prs/\(row.repo)/\(row.number)/diff", query: ["revision": row.revision])
    }

    public func detail(_ row: PullRequestRow) async throws -> Data {
        try await get(path: "prs/\(row.repo)/\(row.number)/detail", query: ["version": row.detail])
    }

    public func keyLines(_ row: PullRequestRow, context: Int) async throws -> Data? {
        try await aiAnswer(
            path: "prs/\(row.repo)/\(row.number)/key-lines", head: row.head, context: context, retry: false
        )
    }

    /// Nil while the Worker's job is running: a model call takes longer than a request may.
    public func aiAnswer(path: String, head: String, context: Int, retry: Bool) async throws -> Data? {
        var query = ["head": head, "context": String(context)]
        query["retry"] = retry ? "1" : nil
        let (data, response) = try await fetch(authorized(path: path, query: query), path: path)
        try await check(response, body: data, path: path)
        return (response as? HTTPURLResponse)?.statusCode == 202 ? nil : data
    }

    public func liveDiff(_ ref: PullRequestRef) async throws -> Data {
        try await get(path: "prs/\(ref.repo)/\(ref.number)/diff")
    }

    public func liveDetail(_ ref: PullRequestRef) async throws -> Data {
        try await get(path: "prs/\(ref.repo)/\(ref.number)/detail")
    }

    /// GitHub's refusal comes back in its own words, and the PR as it now stands otherwise.
    public func write(_ write: PRWrite, to ref: PullRequestRef) async throws -> Data {
        let path = "prs/\(ref.repo)/\(ref.number)/write"
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(write)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request, path: path)
        try await check(response, body: data, path: path)
        return data
    }

    /// One try of an outbox item (`WriteOutbox`): its body already carries its `client_ref`.
    public func outboxRequest(path: String, body: Data) async throws -> URLRequest {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// GitHub's refusal in its own words, as the Worker passes it on, else what the status means.
    public static func refusal(status: Int, body: Data) -> String {
        PRWorkerError(status: status, body: body).localizedDescription
    }

    /// The conversation on this PR with its AI agent; empty until the first question.
    public func askChat(_ ref: PullRequestRef) async throws -> PRAskChat {
        let path = "prs/\(ref.repo)/\(ref.number)/ask"
        return try decode(PRAskChat.self, from: await get(path: path), path: path)
    }

    /// Once: a retry after a timeout could ask twice. The agent's answer comes through `askChat`.
    public func ask(_ question: PRAskQuestion, about ref: PullRequestRef) async throws -> PRAskChat {
        let path = "prs/\(ref.repo)/\(ref.number)/ask"
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(question)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request, path: path)
        try await check(response, body: data, path: path)
        return try decode(PRAskChat.self, from: data, path: path)
    }

    /// A read of any route on the Worker, decoded.
    public func read<Answer: Decodable>(
        _ path: String, query: [String: String] = [:], as type: Answer.Type
    ) async throws -> Answer {
        try decode(type, from: await get(path: path, query: query), path: path)
    }

    /// A POST whose answer is decoded, and whose refusal comes back in the Worker's words.
    public func send<Answer: Decodable>(_ path: String, _ body: some Encodable & Sendable, as type: Answer.Type) async throws
        -> Answer {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request, path: path)
        try await check(response, body: data, path: path)
        return try decode(type, from: data, path: path)
    }

    public func post(_ path: String, _ body: some Encodable & Sendable) async throws {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request, path: path)
        try await check(response, body: data, path: path)
    }

    /// A `DELETE` of any route on the Worker.
    public func delete(_ path: String) async throws {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "DELETE"
        let (data, response) = try await fetch(request, path: path)
        try await check(response, body: data, path: path)
    }

    private func authorized(path: String, query: [String: String]) async throws -> URLRequest {
        guard let base = access.baseURL() else {
            throw PRWorkerError.notPaired
        }
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let url = base.appending(path: path, directoryHint: .notDirectory).appending(queryItems: items)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await access.bearer())", forHTTPHeaderField: "Authorization")
        return request
    }

    /// One try: a failure of the connection itself is reported here, a refusal by `check`.
    private func fetch(_ request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        do {
            return try await exchange(request)
        } catch {
            if let failure = PRRequestFailure(transport: error) {
                reportFailure(path: path, failure)
            }
            throw error
        }
    }

    private func get(path: String, query: [String: String] = [:]) async throws -> Data {
        let (data, response) = try await fetch(authorized(path: path, query: query), path: path)
        try await check(response, body: data, path: path)
        return data
    }

    /// A refusal in the Worker's words where its body has them (`{"error": "…"}`), else what the status means.
    private func check(_ response: URLResponse, body: Data, path: String) async throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            reportFailure(path: path, .status(status))
            if status == 401 {
                await access.discard()
            }
            throw PRWorkerError(status: status, body: body, area: PRRequestArea(path: path))
        }
    }

    /// An answer this app can't read is a failure of its own kind.
    private func decode<Answer: Decodable>(_ type: Answer.Type, from data: Data, path: String) throws -> Answer {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            reportFailure(path: path, .unreadable)
            throw error
        }
    }
}
