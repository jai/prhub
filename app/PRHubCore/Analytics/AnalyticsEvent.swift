import Foundation

/// Everything PRHub reports about how it is used (AGENTS.md, "Analytics"). A case carries only the closed enums below,
/// counts and flags: no string, URL or PR reference, so no login, repo, path, title or code can reach an event.
public enum AnalyticsEvent: Equatable, Sendable {
    case screenViewed(AnalyticsScreen)
    /// A way in tried from onboarding. "Try with sample PRs" is `.samples`.
    case onboardingPathChosen(OnboardingPath)
    case signInStarted(SignInContext)
    case signInSucceeded
    case signInFailed(SignInFailureCode)
    case workerPaired
    case workerPairingFailed(PairingFailureCode)
    /// Settings' way back from the samples.
    case samplesLeft
    case anthropicKeySet
    case anthropicKeyRemoved
    /// Settings' Connect Linear, once the Worker has the key; and Disconnect Linear.
    case linearConnected
    case linearDisconnected
    /// The offer to turn on review alerts, or Settings' ask again: the system's answer, or Not now.
    case alertsAnswered(AlertsAnswer)
    /// An action in Settings on the hosted account that the Worker refused or could not be asked: which one, and why.
    case accountActionFailed(AccountAction, AccountActionError)
    case signedOut
    case accountDeleted
    case workerDisconnected
    case diffFontChanged(DiffFontFace, size: Int)
    /// From PRKit (`PRKitEvent.contentShown`): a PR's content on screen, how it was opened, whether the phone had it,
    /// and how long it took from the tap, waiting on the Worker and reading it.
    case pullRequestOpened(
        PROpenReport.Source, PROpenReport.Cache, timeToContentMs: Int, networkMs: Int, decodeMs: Int
    )
    /// How PRHubNotifications' fetch of an alert's PR went, and how long it took.
    case pushPrefetch(PRPushPrefetch.Outcome, milliseconds: Int)
    case pullRequestsSynced(PRSyncTrigger, PRSyncOutcome)
    /// The PR list's pull to refresh (issue #55): counts, timings and the scroll view's state, never a PR.
    case listRefreshStarted(rows: Int)
    case listRefreshFinished(PRListRefreshFinish)
    case listRefreshStuck(PRListRefreshStuck)
    case listRefreshBackgrounded(milliseconds: Int)
    case pullRequestWriteRefused
    /// From PRKit (`PRKitEvent.requestFailed`): a request to the Worker failed, what it was for and how. Each area's
    /// kind of failure at most once a minute.
    case requestFailed(PRRequestArea, PRRequestFailure)
    /// Update available showed (`PRHubUpdate`): the TestFlight group and the build it offered. The running build is
    /// the vendor's own `$app_build`.
    case updateOffered(TestFlightGroup, build: Int)
    case updateAnswered(UpdateAnswer)
    /// Update's TestFlight link did not open: TestFlight isn't on the phone.
    case updateOpenFailed
    /// A `prhub-pr://open` handoff, as the share sheet sends one: opened, or not a PR PRHub opens.
    case pullRequestLinkOpened(PRLinkOutcome)
    /// A tapped review alert that opened nothing, and why.
    case alertIgnored(AlertIgnoredReason)
    /// The hosted Worker ended this phone's session: GitHub signed the person out (Sign in again shows), or the
    /// Worker no longer knows the session (signed out elsewhere, or the account deleted).
    case sessionEnded(SessionEndReason)
    /// A Feedback message FeedbackKit's server took (`PRHubFeedbackTransport`): new chat or reply, how many
    /// screenshots, its size and how long it took. Never its words or its screenshots.
    case feedbackSent(FeedbackSend)
    /// A Feedback send that failed, and why: the screen says only "Could not send feedback".
    case feedbackSendFailed(FeedbackSend, PRRequestFailure)
    /// From PRKit (`PRKitEvent.wrote`): a review, comment, merge, edit or other write, and how it went. A failure of
    /// the same kind and why at most once a minute (`limitKey`).
    case pullRequestWrote(PRWriteKind, PRActionOutcome)
    /// From PRKit (`PRKitEvent.aiAnswered`): key lines or a rewrite from the Worker's model, how it went and how long it
    /// took; for key lines whether the AI trash chip shows.
    case aiAnswered(PRAIKind, PRActionOutcome, milliseconds: Int, slop: Bool?)
    /// From PRKit (`PRKitEvent.askSent`): a question to the PR's AI, what asked it and how it went. Never its words.
    case askSent(PRAskOrigin, PRActionOutcome)
    /// The Worker had a question but its agent gave no answer. Once for each question, and once a minute at most.
    case askAnswerFailed
    /// A question saved on the phone that the Worker refused after its sheet had gone. Not its words.
    case askRefused
    case askReviewUsed(PRAskReviewUse)
    /// A Linear comment the AI proposed, posted on the user's yes, or why not.
    case askLinearPosted(PRActionOutcome)

    /// The event's name in the vendor's project: one literal each.
    public var name: String {
        switch self {
        case .screenViewed: "$screen"
        case .onboardingPathChosen: "onboarding_path_chosen"
        case .signInStarted: "sign_in_started"
        case .signInSucceeded: "sign_in_succeeded"
        case .signInFailed: "sign_in_failed"
        case .workerPaired: "worker_paired"
        case .workerPairingFailed: "worker_pairing_failed"
        case .samplesLeft: "samples_left"
        case .anthropicKeySet: "anthropic_key_set"
        case .anthropicKeyRemoved: "anthropic_key_removed"
        case .linearConnected: "linear_connected"
        case .linearDisconnected: "linear_disconnected"
        case .accountActionFailed: "account_action_failed"
        case .alertsAnswered: "alerts_answered"
        case .signedOut: "signed_out"
        case .accountDeleted: "account_deleted"
        case .workerDisconnected: "worker_disconnected"
        case .diffFontChanged: "diff_font_changed"
        case .pullRequestOpened: "pr_opened"
        case .pushPrefetch: "push_prefetch"
        case .pullRequestsSynced: "prs_synced"
        case .listRefreshStarted: "pr_list_refresh_started"
        case .listRefreshFinished: "pr_list_refresh_finished"
        case .listRefreshStuck: "pr_list_refresh_stuck"
        case .listRefreshBackgrounded: "pr_list_refresh_backgrounded"
        case .pullRequestWriteRefused: "pr_write_refused"
        case .requestFailed: "request_failed"
        case .updateOffered: "update_offered"
        case .updateAnswered: "update_answered"
        case .updateOpenFailed: "update_open_failed"
        case .pullRequestLinkOpened: "pr_link_opened"
        case .alertIgnored: "alert_ignored"
        case .sessionEnded: "session_ended"
        case .feedbackSent: "feedback_sent"
        case .feedbackSendFailed: "feedback_send_failed"
        case .pullRequestWrote: "pr_write"
        case .aiAnswered: "ai_answer"
        case .askSent: "ask_sent"
        case .askAnswerFailed: "ask_answer_failed"
        case .askRefused: "ask_refused"
        case .askReviewUsed: "ask_review_used"
        case .askLinearPosted: "ask_linear_posted"
        }
    }

    public var properties: [String: AnalyticsValue] {
        switch self {
        case let .screenViewed(screen): ["$screen_name": .word(screen.rawValue)]
        case let .onboardingPathChosen(path): ["path": .word(path.rawValue)]
        case let .signInStarted(context): ["context": .word(context.rawValue)]
        case let .signInFailed(code): ["code": .word(code.rawValue)]
        case let .workerPairingFailed(code): ["code": .word(code.rawValue)]
        case let .diffFontChanged(face, size): ["face": .word(face.rawValue), "size": .number(size)]
        case let .pullRequestsSynced(trigger, outcome):
            ["trigger": .word(trigger.rawValue), "outcome": .word(outcome.analyticsWord)]
        case let .pullRequestOpened(source, cache, timeToContent, network, decode):
            [
                "source": .word(source.rawValue), "cache": .word(cache.rawValue),
                "time_to_content_ms": .number(timeToContent), "network_ms": .number(network),
                "decode_ms": .number(decode),
            ]
        case let .listRefreshStarted(rows): ["rows": .number(rows)]
        case let .listRefreshFinished(finish):
            [
                "outcome": .word(finish.outcome.rawValue), "duration_ms": .number(finish.milliseconds),
                "rows_before": .number(finish.rowsBefore), "rows_after": .number(finish.rowsAfter),
                "source": .word(finish.source.rawValue),
            ]
        case let .listRefreshStuck(stuck):
            [
                "gap": .number(stuck.gap), "content_offset_y": .number(stuck.offsetY),
                "adjusted_inset_top": .number(stuck.insetTop), "resting_inset_top": .number(stuck.restingInsetTop),
                "is_refreshing": .number(stuck.isRefreshing ? 1 : 0), "is_loading": .number(stuck.isLoading ? 1 : 0),
                "is_interacting": .number(stuck.isInteracting ? 1 : 0), "scene": .word(stuck.scene.rawValue),
            ]
        case let .listRefreshBackgrounded(milliseconds): ["ms": .number(milliseconds)]
        case let .pushPrefetch(outcome, milliseconds):
            ["outcome": .word(outcome.rawValue), "ms": .number(milliseconds)]
        case let .requestFailed(area, failure):
            ["area": .word(area.rawValue)].merging(failure.properties) { first, _ in first }
        case let .updateOffered(group, build): ["group": .word(group.rawValue), "build": .number(build)]
        case let .updateAnswered(answer): ["answer": .word(answer.rawValue)]
        case let .pullRequestLinkOpened(outcome): ["outcome": .word(outcome.rawValue)]
        case let .alertIgnored(reason): ["reason": .word(reason.rawValue)]
        case let .sessionEnded(reason): ["reason": .word(reason.rawValue)]
        case let .feedbackSent(send): send.properties
        case let .feedbackSendFailed(send, failure):
            send.properties.merging(failure.properties) { first, _ in first }
        case let .pullRequestWrote(kind, outcome):
            ["kind": .word(kind.rawValue)].merging(outcome.properties) { first, _ in first }
        case let .aiAnswered(kind, outcome, milliseconds, slop):
            ["kind": .word(kind.rawValue), "ms": .number(milliseconds)]
                .merging(outcome.properties) { first, _ in first }
                .merging(slop.map { ["slop": .number($0 ? 1 : 0)] } ?? [:]) { first, _ in first }
        case let .askSent(origin, outcome):
            ["origin": .word(origin.rawValue)].merging(outcome.properties) { first, _ in first }
        case let .askReviewUsed(use): ["use": .word(use.rawValue)]
        case let .askLinearPosted(outcome): outcome.properties
        case let .alertsAnswered(answer): ["answer": .word(answer.rawValue)]
        case let .accountActionFailed(action, error):
            ["action": .word(action.rawValue), "code": .word(AccountFailureCode(error).rawValue)]
                .merging(error.status.map { ["status": .number($0)] } ?? [:]) { first, _ in first }
        case .signInSucceeded, .workerPaired, .samplesLeft, .anthropicKeySet, .anthropicKeyRemoved, .signedOut,
             .accountDeleted, .workerDisconnected, .pullRequestWriteRefused, .askAnswerFailed, .askRefused,
             .linearConnected, .linearDisconnected, .updateOpenFailed:
            [:]
        }
    }
}

extension AnalyticsEvent {
    /// A failure that can repeat, by what failed and why: `UsageAnalytics` sends each at most once a minute, as
    /// `PRFailureReporter` does a request's. Nil for an event that is sent each time.
    var limitKey: String? {
        switch self {
        case let .pullRequestWrote(kind, .failed(failure)): "\(name) \(kind.rawValue) \(failure.rawValue)"
        case let .aiAnswered(kind, .failed(failure), _, _): "\(name) \(kind.rawValue) \(failure.rawValue)"
        case let .askSent(origin, .failed(failure)): "\(name) \(origin.rawValue) \(failure.rawValue)"
        case let .askLinearPosted(.failed(failure)): "\(name) \(failure.rawValue)"
        case .askAnswerFailed, .askRefused, .updateOpenFailed: name
        case let .sessionEnded(reason): "\(name) \(reason.rawValue)"
        case let .accountActionFailed(action, error): "\(name) \(action.rawValue) \(AccountFailureCode(error).rawValue)"
        default: nil
        }
    }
}

/// A property's value. Only `AnalyticsEvent.properties` makes one, from the closed enums in this file.
public enum AnalyticsValue: Equatable, Sendable {
    case word(String)
    case number(Int)
}

/// Generic names only: never a PR's title or repo.
/// Update available's buttons.
public enum UpdateAnswer: String, CaseIterable, Sendable {
    case update, later
}

/// What a `prhub-pr://open` handoff came to.
public enum PRLinkOutcome: String, CaseIterable, Sendable {
    case opened
    case notAPullRequest = "not_a_pr"
}

/// Why a tapped review alert opened nothing.
public enum AlertIgnoredReason: String, CaseIterable, Sendable {
    case notPaired = "not_paired"
    case samples
}

/// Why the hosted Worker ended this phone's session.
public enum SessionEndReason: String, CaseIterable, Sendable {
    /// GitHub no longer honours the person's tokens: the `signed_out` push or a `401 signed_out`.
    case githubSignedOut = "github_signed_out"
    /// Any other `401`: the Worker no longer knows this session.
    case workerForgot = "worker_forgot"
}

/// What became of the offer to turn on review alerts.
public enum AlertsAnswer: String, CaseIterable, Sendable {
    case allowed, denied
    case notNow = "not_now"
}

public enum AnalyticsScreen: String, CaseIterable, Sendable {
    case onboarding, samples, prs, feedback, settings
    case signedOut = "signed_out"
}

public enum OnboardingPath: String, CaseIterable, Sendable {
    case signInWithGitHub = "sign_in_with_github"
    case ownWorker = "own_worker"
    case samples
}

public enum SignInContext: String, CaseIterable, Sendable {
    case onboarding
    case signInAgain = "sign_in_again"
}

public enum SignInFailureCode: String, CaseIterable, Sendable {
    case cancelled, denied, expired, unreachable, unreadable, keychain
    case githubRefused = "github_refused"
    case githubUnavailable = "github_unavailable"
    case stateMismatch = "state_mismatch"
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case sessionUnavailable = "session_unavailable"
    case sessionEnded = "session_ended"

    init(_ error: SignInError) {
        self = switch error {
        case .cancelled: .cancelled
        case .denied: .denied
        case .expired: .expired
        case .githubRefused: .githubRefused
        case .githubUnavailable: .githubUnavailable
        case .stateMismatch: .stateMismatch
        case .rateLimited: .rateLimited
        case .unreachable: .unreachable
        case .server: .serverError
        case .unreadable: .unreadable
        case .keychain: .keychain
        case .sessionUnavailable: .sessionUnavailable
        case .sessionEnded: .sessionEnded
        }
    }
}

public enum PairingFailureCode: String, CaseIterable, Sendable {
    case unreachable, unreadable, keychain
    case invalidLink = "invalid_link"
    case codeMalformed = "code_malformed"
    case codeRefused = "code_refused"
    case secretRefused = "secret_refused"
    case pairingUnsupported = "pairing_unsupported"
    case appCode = "app_code"
    case serverError = "server_error"

    /// `unreachable` drops the Worker's host.
    init(_ error: PairingError) {
        self = switch error {
        case .codeMalformed: .codeMalformed
        case .codeRefused: .codeRefused
        case .secretRefused: .secretRefused
        case .pairingUnsupported: .pairingUnsupported
        case .appCode: .appCode
        case .unreachable: .unreachable
        case .server: .serverError
        case .unreadable: .unreadable
        case .keychain: .keychain
        }
    }
}

/// Why an account action failed (`AccountActionError`), as `account_action_failed`'s `code`; a server's status goes in
/// `status`.
enum AccountFailureCode: String, CaseIterable {
    case unreachable, unreadable
    case keyMalformed = "key_malformed"
    case keyRefused = "key_refused"
    case anthropicUnavailable = "anthropic_unavailable"
    case linearKeyMalformed = "linear_key_malformed"
    case linearKeyRefused = "linear_key_refused"
    case linearUnavailable = "linear_unavailable"
    case signedOut = "signed_out"
    case serverError = "server_error"

    init(_ error: AccountActionError) {
        self = switch error {
        case .keyMalformed: .keyMalformed
        case .keyRefused: .keyRefused
        case .anthropicUnavailable: .anthropicUnavailable
        case .linearKeyMalformed: .linearKeyMalformed
        case .linearKeyRefused: .linearKeyRefused
        case .linearUnavailable: .linearUnavailable
        case .signedOut: .signedOut
        case .unreachable: .unreachable
        case .server: .serverError
        case .unreadable: .unreadable
        }
    }
}

private extension AccountActionError {
    var status: Int? {
        if case let .server(status) = self {
            return status
        }
        return nil
    }
}

extension AnalyticsEvent {
    /// What PRKit tells the app, as an event; nil for what is not reported. A badge count changes too often to be
    /// worth one, and a push's sync is reported only when it fails, so a busy repo does not flood the project. A
    /// refused write's or question's words can quote GitHub or the user about the PR, so only that it happened is sent.
    /// A PR is reported once its content shows, with its timings, and not when its screen is made.
    init?(_ event: PRKitEvent) {
        if let action = Self.action(event) {
            self = action
            return
        }
        switch event {
        case .opened:
            return nil
        case let .contentShown(report):
            self = .pullRequestOpened(
                report.source, report.cache, timeToContentMs: report.timeToContentMilliseconds,
                networkMs: report.networkMilliseconds, decodeMs: report.decodeMilliseconds
            )
        case let .synced(trigger, outcome):
            let isPush = trigger == .silentPush || trigger == .otherPush
            guard !isPush || outcome == .failed else {
                return nil
            }
            self = .pullRequestsSynced(trigger, outcome)
        case .reviewRequests:
            return nil
        case .writeRefused:
            self = .pullRequestWriteRefused
        case .questionRefused:
            self = .askRefused
        case let .requestFailed(area, failure):
            self = .requestFailed(area, failure)
        case let .listRefreshStarted(rows):
            self = .listRefreshStarted(rows: rows)
        case let .listRefreshFinished(finish):
            self = .listRefreshFinished(finish)
        case let .listRefreshStuck(stuck):
            self = .listRefreshStuck(stuck)
        case let .listRefreshBackgrounded(milliseconds):
            self = .listRefreshBackgrounded(milliseconds: milliseconds)
        case .wrote, .aiAnswered, .askSent, .askAnswerFailed, .askReviewUsed, .askLinearPosted:
            return nil
        }
    }

    /// The user's actions on a PR and its AI, each as it came.
    private static func action(_ event: PRKitEvent) -> AnalyticsEvent? {
        switch event {
        case let .wrote(kind, outcome): .pullRequestWrote(kind, outcome)
        case let .aiAnswered(kind, outcome, milliseconds, slop):
            .aiAnswered(kind, outcome, milliseconds: milliseconds, slop: slop)
        case let .askSent(origin, outcome): .askSent(origin, outcome)
        case .askAnswerFailed: .askAnswerFailed
        case let .askReviewUsed(use): .askReviewUsed(use)
        case let .askLinearPosted(outcome): .askLinearPosted(outcome)
        default: nil
        }
    }
}

private extension PRSyncOutcome {
    var analyticsWord: String {
        switch self {
        case .changed: "changed"
        case .unchanged: "unchanged"
        case .failed: "failed"
        }
    }
}

/// How a request failed, as `request_failed`'s `failure`: a status (sent in `status`) or why there was none.
enum RequestFailureKind: String, CaseIterable {
    case status, offline, timeout, network, unreadable

    init(_ failure: PRRequestFailure) {
        self = switch failure {
        case .status: .status
        case .offline: .offline
        case .timeout: .timeout
        case .network: .network
        case .unreadable: .unreadable
        }
    }
}

/// `outcome`: `done`, `queued` or `failed`, and a failure's `failure` (`PRActionFailure`).
enum ActionOutcomeWord: String, CaseIterable {
    case done, queued, failed
}

extension PRActionOutcome {
    var properties: [String: AnalyticsValue] {
        switch self {
        case .done: ["outcome": .word(ActionOutcomeWord.done.rawValue)]
        case .queued: ["outcome": .word(ActionOutcomeWord.queued.rawValue)]
        case let .failed(failure):
            ["outcome": .word(ActionOutcomeWord.failed.rawValue), "failure": .word(failure.rawValue)]
        }
    }
}

private extension FeedbackSend {
    var properties: [String: AnalyticsValue] {
        [
            "kind": .word(kind.rawValue), "images": .number(images), "kb": .number(kilobytes),
            "ms": .number(milliseconds),
        ]
    }
}

private extension PRRequestFailure {
    /// `failure`, and `status` when there was one.
    var properties: [String: AnalyticsValue] {
        ["failure": .word(RequestFailureKind(self).rawValue)]
            .merging(status.map { ["status": .number($0)] } ?? [:]) { first, _ in first }
    }

    /// The HTTP status, when there was one.
    var status: Int? {
        if case let .status(code) = self {
            return code
        }
        return nil
    }
}
