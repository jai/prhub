import Foundation
import PRKitNetwork

/// Why the pr-worker didn't answer with what was asked, read once from its status and body. Each case says what
/// happened and what to do; the status stays in `unexpected` for a log, never on screen.
public enum PRWorkerError: LocalizedError, Equatable, Sendable {
    /// PRHub before it has paired: nothing was sent.
    case notPaired
    /// `401`: the bearer was dropped, and the next request reads a new one.
    case signedOut
    /// `404`, `410`.
    case notFound
    /// `406`, `413`: GitHub won't send something this big.
    case tooLarge
    /// `400`, `422`: the Worker couldn't read what the phone sent, so sending it again can't help.
    case unreadableRequest
    /// `429`.
    case limited
    /// `5xx`.
    case unavailable
    case unexpected(status: Int)
    /// The Worker's own words: GitHub's for a write, the model's for an AI answer. `isPermanent` from its status.
    case refused(String, isPermanent: Bool = false)

    public init(status: Int) {
        switch status {
        case 401: self = .signedOut
        case 404, 410: self = .notFound
        case 406, 413: self = .tooLarge
        case 400, 422: self = .unreadableRequest
        case 429: self = .limited
        case 500...599: self = .unavailable
        default: self = .unexpected(status: status)
        }
    }

    /// The Worker's words when its body carries them, else what the status means.
    public init(status: Int, body: Data) {
        if let refusal = try? JSONDecoder().decode(WorkerRefusal.self, from: body) {
            self = .refused(refusal.error, isPermanent: PRWorkerError(status: status).isPermanent)
        } else {
            self.init(status: status)
        }
    }

    /// Asking again gets the same answer.
    public var isPermanent: Bool {
        switch self {
        case .notFound, .tooLarge, .unreadableRequest: true
        case let .refused(_, isPermanent): isPermanent
        case .notPaired, .signedOut, .limited, .unavailable, .unexpected: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This phone isn't connected to a Worker yet. Connect one in Settings."
        case .signedOut: "The Worker didn't recognise this phone. Try again; if it keeps happening, connect it again."
        case .notFound: "The Worker can't find this PR. It may have been deleted or moved."
        case .tooLarge: "This is too large for GitHub to send."
        case .unreadableRequest: "The Worker couldn't read that request. Update the app and your Worker, then retry."
        case .limited: "Too many requests for now. Wait a minute and try again."
        case .unavailable: "The Worker couldn't answer just now. Try again in a minute."
        case .unexpected: "The Worker gave an answer this app doesn't know. Update the app and your Worker."
        case let .refused(reason, _): reason
        }
    }
}

/// `{"error": "…"}`: a PR route's refusal, in words for the phone.
private struct WorkerRefusal: Decodable {
    let error: String
}

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

    public struct List: Decodable, Sendable {
        public let prs: [PullRequestRow]
        // swiftlint:disable:next identifier_name
        public let synced_at: Double
    }

    public func pullRequests() async throws -> List {
        try await JSONDecoder().decode(List.self, from: get(path: "prs"))
    }

    public struct Merged: Decodable, Sendable {
        public let prs: [PullRequestRow]
    }

    /// The last 50 merged PRs Jai wrote, or reviewed, newest merge first. Read from GitHub each time: they are kept
    /// nowhere.
    public func mergedPullRequests(reviewed: Bool) async throws -> [PullRequestRow] {
        try await JSONDecoder().decode(
            Merged.self, from: get(path: "prs/merged", query: reviewed ? ["of": "reviewed"] : [:])
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
        let (data, response) = try await fetch(authorized(path: path, query: query))
        try await check(response, body: data)
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
        var request = try await authorized(path: "prs/\(ref.repo)/\(ref.number)/write", query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(write)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try await check(response, body: data)
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
        try await JSONDecoder().decode(PRAskChat.self, from: get(path: "prs/\(ref.repo)/\(ref.number)/ask"))
    }

    /// Once: a retry after a timeout could ask twice. The agent's answer comes through `askChat`.
    public func ask(_ question: PRAskQuestion, about ref: PullRequestRef) async throws -> PRAskChat {
        var request = try await authorized(path: "prs/\(ref.repo)/\(ref.number)/ask", query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(question)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try await check(response, body: data)
        return try JSONDecoder().decode(PRAskChat.self, from: data)
    }

    /// A read of any route on the Worker, decoded.
    public func read<Answer: Decodable>(
        _ path: String, query: [String: String] = [:], as type: Answer.Type
    ) async throws -> Answer {
        try await JSONDecoder().decode(type, from: get(path: path, query: query))
    }

    /// A POST whose answer is decoded, and whose refusal comes back in the Worker's words.
    public func send<Answer: Decodable>(_ path: String, _ body: some Encodable & Sendable, as type: Answer.Type) async throws
        -> Answer {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try await check(response, body: data)
        return try JSONDecoder().decode(type, from: data)
    }

    public func post(_ path: String, _ body: some Encodable & Sendable) async throws {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try await check(response, body: data)
    }

    /// A `DELETE` of any route on the Worker.
    public func delete(_ path: String) async throws {
        var request = try await authorized(path: path, query: [:])
        request.httpMethod = "DELETE"
        let (data, response) = try await fetch(request)
        try await check(response, body: data)
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

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await exchange(request)
    }

    private func get(path: String, query: [String: String] = [:]) async throws -> Data {
        let (data, response) = try await fetch(authorized(path: path, query: query))
        try await check(response, body: data)
        return data
    }

    /// A refusal in the Worker's words where its body has them (`{"error": "…"}`), else what the status means.
    private func check(_ response: URLResponse, body: Data) async throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                await access.discard()
            }
            throw PRWorkerError(status: status, body: body)
        }
    }
}
