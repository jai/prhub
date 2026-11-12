import Foundation

/// Everything PRHub reports about how it is used (AGENTS.md, "Analytics"). A case carries only the closed enums below,
/// counts and flags: no string, URL or PR reference, so no login, repo, path, title or code can reach an event.
enum AnalyticsEvent: Equatable, Sendable {
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
    case pullRequestWriteRefused

    /// The event's name in the vendor's project: one literal each.
    var name: String {
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
        case .signedOut: "signed_out"
        case .accountDeleted: "account_deleted"
        case .workerDisconnected: "worker_disconnected"
        case .diffFontChanged: "diff_font_changed"
        case .pullRequestOpened: "pr_opened"
        case .pushPrefetch: "push_prefetch"
        case .pullRequestsSynced: "prs_synced"
        case .pullRequestWriteRefused: "pr_write_refused"
        }
    }

    var properties: [String: AnalyticsValue] {
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
        case let .pushPrefetch(outcome, milliseconds):
            ["outcome": .word(outcome.rawValue), "ms": .number(milliseconds)]
        case .signInSucceeded, .workerPaired, .samplesLeft, .anthropicKeySet, .anthropicKeyRemoved, .signedOut,
             .accountDeleted, .workerDisconnected, .pullRequestWriteRefused:
            [:]
        }
    }
}

/// A property's value. Only `AnalyticsEvent.properties` makes one, from the closed enums in this file.
enum AnalyticsValue: Equatable, Sendable {
    case word(String)
    case number(Int)
}

/// Generic names only: never a PR's title or repo.
enum AnalyticsScreen: String, CaseIterable, Sendable {
    case onboarding, samples, prs, feedback, settings
    case signedOut = "signed_out"
}

enum OnboardingPath: String, CaseIterable, Sendable {
    case signInWithGitHub = "sign_in_with_github"
    case ownWorker = "own_worker"
    case samples
}

enum SignInContext: String, CaseIterable, Sendable {
    case onboarding
    case signInAgain = "sign_in_again"
}

enum SignInFailureCode: String, CaseIterable, Sendable {
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

enum PairingFailureCode: String, CaseIterable, Sendable {
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

extension AnalyticsEvent {
    /// What PRKit tells the app, as an event; nil for what is not reported. A badge count changes too often to be
    /// worth one, and a push's sync is reported only when it fails, so a busy repo does not flood the project. A
    /// refused write's words can quote GitHub about the PR, so only that it happened is sent. A PR is reported once its
    /// content shows, with its timings, and not when its screen is made.
    init?(_ event: PRKitEvent) {
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
            return nil
        }
    }
}

extension PRSyncOutcome {
    fileprivate var analyticsWord: String {
        switch self {
        case .changed: "changed"
        case .unchanged: "unchanged"
        case .failed: "failed"
        }
    }
}
