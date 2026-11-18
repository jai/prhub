import Foundation
import PRKitCore

/// How an action of the user's went (`PRKitEvent`): done, saved on the phone and still going, or failed and why. A
/// closed set, so a report of one carries none of GitHub's, the model's or the user's words.
public enum PRActionOutcome: Equatable, Hashable, Sendable {
    case done
    /// Saved on the phone (the host's outbox): it goes on by itself.
    case queued
    case failed(PRActionFailure)

    /// What became of a write, or of a question to the PR's AI.
    init(_ outcome: PRWriteOutcome) {
        switch outcome {
        case .posted: self = .done
        case .queued: self = .queued
        }
    }

    /// Nil for no failure at all: the screen left and cancelled it.
    init?(error: any Error) {
        guard let failure = PRActionFailure(error) else {
            return nil
        }
        self = .failed(failure)
    }
}

/// Why an action failed, from the error alone: the request's own failure, the Worker's status as `PRWorkerError` reads
/// it, or the phone's refusal before anything was sent. Never the error's words.
public enum PRActionFailure: String, CaseIterable, Sendable {
    case offline, timeout, network
    /// An answer this app could not read.
    case unreadable
    /// `401`.
    case signedOut = "signed_out"
    /// `404`, `410`: the PR, or what was asked for, isn't there.
    case notFound = "not_found"
    /// `406`, `413`.
    case tooLarge = "too_large"
    /// `400`, `422`: the Worker couldn't read what the phone sent.
    case badRequest = "bad_request"
    /// `429`.
    case rateLimited = "rate_limited"
    /// `5xx`.
    case unavailable
    /// A status this app doesn't know.
    case unexpected
    /// Refused in the Worker's own words: GitHub's for a write, the model's for an AI answer, Linear's for a comment.
    case refused
    /// The PR moved on to a newer commit than the one asked about.
    case moved
    /// Refused on the phone before anything was sent: no Worker yet, a sample PR, a PR not loaded yet.
    case local
    case other

    /// Nil for a cancelled request.
    public init?(_ error: any Error) {
        switch error {
        case let error as URLError:
            switch PRRequestFailure(transport: error) {
            case nil: return nil
            case .offline: self = .offline
            case .timeout: self = .timeout
            case .status, .network: self = .network
            case .unreadable: self = .unreadable
            }
        case is CancellationError: return nil
        case let error as PRWorkerError: self.init(error)
        case is DecodingError: self = .unreadable
        case is PRLocalRefusal, is SamplesPostNothing: self = .local
        case is PRAIHeadMoved: self = .moved
        default: self = .other
        }
    }

    init(_ error: PRWorkerError) {
        self = switch error {
        case .notPaired: .local
        case .signedOut: .signedOut
        case .notFound, .unreachable: .notFound
        case .tooLarge: .tooLarge
        case .unreadableRequest: .badRequest
        case .limited: .rateLimited
        case .unavailable: .unavailable
        case .unexpected: .unexpected
        case .refused: .refused
        }
    }
}

/// A write of the user's, by what it does on GitHub (`PRKitEvent.wrote`).
public enum PRWriteKind: String, CaseIterable, Sendable {
    case comment
    /// A comment on one line, posted now.
    case line
    case reply
    case approve
    case requestChanges = "request_changes"
    /// A review that only comments, with or without line comments.
    case review
    case resolve, reopen
    case viewed, unviewed
    case updateBranch = "update_branch"
    /// Leaving a review request: the list's swipe.
    case removeRequest = "remove_request"
    case checkbox
    /// Saving the description, typed or rewritten by the model.
    case editBody = "edit_body"
    case merge

    public init(_ write: PRWrite) {
        self = switch write {
        case .comment: .comment
        case .line: .line
        case .reply: .reply
        case .review(.approve, _, _, _): .approve
        case .review(.requestChanges, _, _, _): .requestChanges
        case .review(.comment, _, _, _): .review
        case let .resolve(_, resolved): resolved ? .resolve : .reopen
        case let .viewed(_, _, viewed): viewed ? .viewed : .unviewed
        case .updateBranch: .updateBranch
        case .removeRequest: .removeRequest
        case .checkbox: .checkbox
        case .editBody: .editBody
        case .merge: .merge
        }
    }
}
