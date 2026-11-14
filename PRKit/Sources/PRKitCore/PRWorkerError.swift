import Foundation

/// Why the pr-worker didn't answer with what was asked, read once from its status and body. Each case says what
/// happened and what to do; the status stays in `unexpected` for a log, never on screen.
public enum PRWorkerError: LocalizedError, Equatable, Sendable {
    /// PRHub before it has paired: nothing was sent.
    case notPaired
    /// `401`: the bearer was dropped, and the next request reads a new one.
    case signedOut
    /// `404`, `410` on a PR's route.
    case notFound
    /// `404`, `410` on any other route (`PRRequestArea.isPullRequest`): what was asked for isn't there to answer.
    case unreachable(PRRequestArea)
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
        self.init(status: status, body: body, area: .prs)
    }

    /// As `init(status:body:)`, for a request of this area: a `404` off a PR's route doesn't speak of a PR.
    public init(status: Int, body: Data, area: PRRequestArea) {
        if let refusal = try? JSONDecoder().decode(WorkerRefusal.self, from: body) {
            self = .refused(refusal.error, isPermanent: PRWorkerError(status: status).isPermanent)
        } else if (status == 404 || status == 410) && !area.isPullRequest {
            self = .unreachable(area)
        } else {
            self.init(status: status)
        }
    }

    /// Asking again gets the same answer.
    public var isPermanent: Bool {
        switch self {
        case .notFound, .tooLarge, .unreadableRequest: true
        case let .refused(_, isPermanent): isPermanent
        case .notPaired, .signedOut, .limited, .unavailable, .unexpected, .unreachable: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This phone isn't connected to a Worker yet. Connect one in Settings."
        case .signedOut: "The Worker didn't recognise this phone. Try again; if it keeps happening, connect it again."
        case .notFound: "The Worker can't find this PR. It may have been deleted or moved."
        case .unreachable(.feedback): "Feedback can't be reached. Try again."
        case .unreachable(.config):
            "The Worker didn't send its settings. Try again; if it keeps happening, update your Worker."
        case .unreachable: "The Worker can't answer this yet. Try again, or update your Worker."
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
