import Foundation
import PRKitCore

/// What the app PRKit is embedded in gives it. PRHub's is `PRHubPRHost` (app/PRHub/App/PRHubHost.swift).
@MainActor
public protocol PRKitHost: AnyObject, Sendable {
    /// Where every request goes and the bearer it carries. Read once, when the kit is made.
    var access: PRViewerAccess { get }
    /// Whether the app is in front: a request made then waits for a network, one from a background wake does not.
    func isInForeground() async -> Bool
    /// What the Worker serves and where the org filter starts. Read each time a screen asks, so a new Worker config
    /// shows at once.
    var configuration: PRKitConfiguration { get }
    /// A queue that keeps a write until the Worker has it (`PRKitOutbox`); nil sends each write straight to the Worker.
    var outbox: (any PRKitOutbox)? { get }
    /// `production` or `sandbox`: the APNs environment `POST /device/register` names with the push token.
    var apnsEnvironment: String { get }
    /// Made-up PRs and no Worker: nothing then leaves the phone (`PRSampleSet`).
    var samples: PRSampleSet? { get }
    /// What a test or benchmark launch asks of the PRs tab; `.none` in a normal launch.
    var launchOptions: PRKitLaunchOptions { get }
    /// Everything PRKit tells the app, as it happens (`PRKitEvent`).
    func receive(_ event: PRKitEvent)
    /// A PR's files that failed to download or be written: for the host's event log.
    func log(_ line: String)
    /// Where the PR mirror keeps its files (`PRMirrorLocation`): the app group's, so a Notification Service Extension
    /// can prefetch an alert's PR (`PRPushPrefetch`). Nil: the app's caches.
    var mirrorDirectory: URL? { get }
}

extension PRKitHost {
    public var mirrorDirectory: URL? { nil }
}

/// The features the PR screens follow and the org filter's starting point. Agent Pager's is `everything`; PRHub's
/// follows its pr-worker's `GET /device/config` (docs/api.md).
public struct PRKitConfiguration: Equatable, Sendable {
    public enum Feature: Sendable {
        case askAI, keyLines, rewrite
        /// The Worker pushes: the push token goes to its `POST /device/register`.
        case push
    }

    public var features: Set<Feature>
    public var orgDefault: PROrgDefault
    /// The GitHub login the Worker acts as: who a sample PR's review is from. Nil where it is not known.
    public var login: String?
    /// What the PR list says once the Worker has synced and has no PRs; nil says nothing.
    public var emptyHint: PREmptyHint?

    public init(features: Set<Feature>, orgDefault: PROrgDefault, login: String? = nil, emptyHint: PREmptyHint? = nil) {
        self.features = features
        self.orgDefault = orgDefault
        self.login = login
        self.emptyHint = emptyHint
    }

    /// Every feature, and every owner in the list until someone picks a filter.
    public static let everything = PRKitConfiguration(
        features: [.askAI, .keyLines, .rewrite, .push], orgDefault: .everyOwner
    )

    public func isOn(_ feature: Feature) -> Bool {
        features.contains(feature)
    }
}

/// The host's words for an empty PR list, and a link that may fill it: PRHub's hosted service points at installing its
/// GitHub App.
public struct PREmptyHint: Equatable, Sendable {
    public var title: String
    public var message: String
    public var linkTitle: String
    public var link: URL

    public init(title: String, message: String, linkTitle: String, link: URL) {
        self.title = title
        self.message = message
        self.linkTitle = linkTitle
        self.link = link
    }
}

/// Where a PR write goes when the host keeps writes on the phone until the Worker has them (Agent Pager's
/// `WriteOutbox`). Each call answers with the item's id; the host hands GitHub's answer or refusal back to
/// `PRKitController.outboxAnswered` or `outboxRefused` under that id.
@MainActor
public protocol PRKitOutbox: AnyObject {
    func enqueue(prWrite write: PRWrite, to ref: PullRequestRef) async throws -> String
    func enqueue(prAIChat question: PRAskQuestion, about ref: PullRequestRef) async throws -> String
    /// Whether a question to this PR's AI chat is still on the phone.
    func hasQueuedAIChat(about ref: PullRequestRef) -> Bool
}

/// What a UI test or a benchmark launch asks the PRs tab to do once it is showing.
public struct PRKitLaunchOptions: Sendable {
    /// The row, by `owner/repo#N`, to open three seconds after the tab shows.
    public var benchmarkRow: String?
    /// A link to show two seconds after that, as a notification would.
    public var linkAfterOpening: PullRequestRef?

    public init(benchmarkRow: String? = nil, linkAfterOpening: PullRequestRef? = nil) {
        self.benchmarkRow = benchmarkRow
        self.linkAfterOpening = linkAfterOpening
    }

    public static let none = PRKitLaunchOptions()

    var isEmpty: Bool { benchmarkRow == nil && linkAfterOpening == nil }
}

/// What PRKit tells its host (`PRKitHost.receive`).
public enum PRKitEvent: Equatable, Sendable {
    /// A PR's screen was made: from a tap, a link or `PRKitController.open`.
    case opened(PullRequestRef)
    /// A sync with the Worker ended.
    case synced(PRSyncTrigger, PRSyncOutcome)
    /// How many PRs ask for the user's review now, the ones swiped away left out: for a badge.
    case reviewRequests(Int)
    /// GitHub refused a write after its screen had gone. The PRs tab shows these words until they are dismissed.
    case writeRefused(String)
    /// A PR's content is on screen: how it was opened, whether the phone had it, and how long it took.
    case contentShown(PROpenReport)
}

/// One PR opened, from the tap to its content on screen (`PRKitEvent.contentShown`).
public struct PROpenReport: Equatable, Sendable {
    /// What opened it.
    public enum Source: String, CaseIterable, Sendable {
        /// A tapped alert.
        case push
        /// A row of the list.
        case list
        /// A PR link in the app, or one handed to `PRKitController.open`.
        case link
    }

    /// What the phone had when it opened.
    public enum Cache: String, CaseIterable, Sendable {
        /// The PR as it is now: shown at once.
        case hit
        /// An older copy: shown at once, then replaced by the new one.
        case stale
        /// Nothing: read from the Worker while the screen waited.
        case miss
    }

    public let source: Source
    public let cache: Cache
    /// From the tap to content on screen.
    public let timeToContentMilliseconds: Int
    /// Of that, waiting on the Worker: zero when the phone had it.
    public let networkMilliseconds: Int
    /// Of that, reading what arrived or what was on the phone into the screen's content.
    public let decodeMilliseconds: Int

    public init(
        source: Source, cache: Cache, timeToContentMilliseconds: Int, networkMilliseconds: Int, decodeMilliseconds: Int
    ) {
        self.source = source
        self.cache = cache
        self.timeToContentMilliseconds = timeToContentMilliseconds
        self.networkMilliseconds = networkMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
    }
}
