import Foundation
import Synchronization

/// What a request to the Worker was for, read from its route: the area of the app a failure shows in. A closed list,
/// so a report of one carries no repo, PR or path.
public enum PRRequestArea: String, CaseIterable, Sendable {
    /// The list: `prs`, `prs/merged`.
    case prs
    case detail
    case diff
    case ask
    case write
    /// Key lines and their reviewed marks.
    case keyLines = "key_lines"
    case rewrite
    case summary
    /// Quick jump's repos.
    case repos
    /// FeatureKit's requests.
    case feedback
    /// `device/config`.
    case config
    /// The rest of `device/`: the push token and the phone's events.
    case device
    case other

    /// `prs/<owner>/<repo>/<n>/<kind>` by its kind; any other route by its first part.
    public init(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch parts.first {
        case "prs" where parts.count <= 2: self = .prs
        case "prs" where parts.count >= 5: self = Self.pullRequestKinds[parts[4]] ?? .other
        case "repos": self = .repos
        case "feedback": self = .feedback
        case "device": self = parts.count >= 2 && parts[1] == "config" ? .config : .device
        default: self = .other
        }
    }

    private static let pullRequestKinds: [String: PRRequestArea] = [
        "detail": .detail, "diff": .diff, "ask": .ask, "write": .write, "key-lines": .keyLines,
        "key-lines-reviewed": .keyLines, "rewrite": .rewrite, "summary": .summary,
    ]

    /// A PR's own route, where a `404` means the PR is gone.
    public var isPullRequest: Bool {
        switch self {
        case .prs, .detail, .diff, .ask, .write, .keyLines, .rewrite, .summary: true
        case .repos, .feedback, .config, .device, .other: false
        }
    }
}

/// How a request to the Worker failed: its status, or why there was none.
public enum PRRequestFailure: Equatable, Hashable, Sendable {
    /// The Worker, or something in front of it, answered with this status.
    case status(Int)
    /// No network, or the Worker's host could not be reached.
    case offline
    case timeout
    /// Some other failure of the connection itself.
    case network
    /// An answer of the right status this app could not read.
    case unreadable

    /// Nil for a failure that is no failure: the request was cancelled.
    public init?(transport error: any Error) {
        if error is CancellationError {
            return nil
        }
        guard let error = error as? URLError else {
            self = .network
            return
        }
        switch error.code {
        case .cancelled: return nil
        case .timedOut: self = .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            self = .offline
        default: self = .network
        }
    }
}

/// Where a client's failures go (`PRViewerClient.reporting`): each kind once a minute at most, per area. A list that
/// fails every sync while offline, or a polled chat, says so once a minute, not once a request.
final class PRFailureReporter: Sendable {
    static let window: TimeInterval = 60
    private let report: @Sendable (PRRequestArea, PRRequestFailure) -> Void
    private let now: @Sendable () -> Date
    private let lastSent = Mutex<[String: Date]>([:])

    init(
        now: @escaping @Sendable () -> Date = { .now },
        report: @escaping @Sendable (PRRequestArea, PRRequestFailure) -> Void
    ) {
        self.now = now
        self.report = report
    }

    func failed(_ area: PRRequestArea, _ failure: PRRequestFailure) {
        let key = "\(area.rawValue) \(failure)"
        let time = now()
        let isDue = lastSent.withLock { sent in
            if let last = sent[key], time.timeIntervalSince(last) < Self.window {
                return false
            }
            sent[key] = time
            return true
        }
        if isDue {
            report(area, failure)
        }
    }
}
