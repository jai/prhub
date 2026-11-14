import Foundation
import Testing
@testable import PRHub

/// Usage analytics (AGENTS.md, "Analytics"): what each event carries, PRKit's events, the switch in Settings, and that
/// a build without a project, a Debug build and the tests send nothing.
@MainActor
struct AnalyticsTests {
    /// What the vendor was handed.
    final class RecordingAnalytics: Analytics {
        var events: [AnalyticsEvent] = []
        var sharing: [Bool] = []

        func record(_ event: AnalyticsEvent) {
            events.append(event)
        }

        func setSharing(_ isOn: Bool) {
            sharing.append(isOn)
        }
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "prhub-analytics-\(UUID().uuidString)")!
    }

    static func usage(_ sink: RecordingAnalytics, defaults: UserDefaults = defaults()) -> UsageAnalytics {
        UsageAnalytics(hasProject: true, sink: sink, defaults: defaults)
    }

    /// One of each case. `kind` has no default, so a new case fails to compile until it is listed here.
    nonisolated static let everyEvent: [AnalyticsEvent] = [
        .screenViewed(.prs), .onboardingPathChosen(.ownWorker), .signInStarted(.onboarding), .signInSucceeded,
        .signInFailed(.denied), .workerPaired, .workerPairingFailed(.codeRefused), .samplesLeft, .anthropicKeySet,
        .anthropicKeyRemoved, .signedOut, .accountDeleted, .workerDisconnected, .diffFontChanged(.menlo, size: 13),
        .pullRequestOpened(.push, .hit, timeToContentMs: 180, networkMs: 0, decodeMs: 40),
        .pullRequestsSynced(.pull, .changed), .pullRequestWriteRefused, .pushPrefetch(.landed, milliseconds: 412),
        .requestFailed(.feedback, .status(404)), .updateOffered(.internal, build: 235), .updateAnswered(.later),
    ]

    // swiftlint:disable:next cyclomatic_complexity - one arm per case, by design
    nonisolated static func kind(_ event: AnalyticsEvent) -> Int {
        switch event {
        case .screenViewed: 0
        case .onboardingPathChosen: 1
        case .signInStarted: 2
        case .signInSucceeded: 3
        case .signInFailed: 4
        case .workerPaired: 5
        case .workerPairingFailed: 6
        case .samplesLeft: 7
        case .anthropicKeySet: 8
        case .anthropicKeyRemoved: 9
        case .signedOut: 10
        case .accountDeleted: 11
        case .workerDisconnected: 12
        case .diffFontChanged: 13
        case .pullRequestOpened: 14
        case .pullRequestsSynced: 15
        case .pullRequestWriteRefused: 16
        case .pushPrefetch: 17
        case .requestFailed: 18
        case .updateOffered: 19
        case .updateAnswered: 20
        }
    }

    // MARK: - What an event can carry

    @Test func everyCaseIsListed() {
        #expect(Set(Self.everyEvent.map(Self.kind)) == Set(0...20))
    }

    @Test func eachEventHasItsOwnSnakeCaseName() {
        let names = Self.everyEvent.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.wholeMatch(of: /\$?[a-z_]+/) != nil, "\(name)")
        }
    }

    /// No case can carry free text: a login, a repo, a path, a title or code would be a String, a URL or a PR's ref.
    @Test(arguments: everyEvent)
    func noEventCarriesTextOrAPullRequest(_ event: AnalyticsEvent) {
        func check(_ value: Any) {
            #expect(!(value is String || value is Substring || value is URL || value is PullRequestRef),
                    "\(event.name) carries \(type(of: value))")
            Mirror(reflecting: value).children.forEach { check($0.value) }
        }
        Mirror(reflecting: event).children.forEach { check($0.value) }
    }

    /// Every word an event sends is one of a closed set, never typed in.
    @Test(arguments: everyEvent)
    func eachWordComesFromAClosedSet(_ event: AnalyticsEvent) {
        let allowed = Set(
            AnalyticsScreen.allCases.map(\.rawValue) + OnboardingPath.allCases.map(\.rawValue)
                + SignInContext.allCases.map(\.rawValue) + SignInFailureCode.allCases.map(\.rawValue)
                + PairingFailureCode.allCases.map(\.rawValue) + DiffFontFace.allCases.map(\.rawValue)
                + PROpenReport.Source.allCases.map(\.rawValue) + PROpenReport.Cache.allCases.map(\.rawValue)
                + PRPushPrefetch.Outcome.allCases.map(\.rawValue)
                + PRRequestArea.allCases.map(\.rawValue) + RequestFailureKind.allCases.map(\.rawValue)
                + TestFlightGroup.allCases.map(\.rawValue) + UpdateAnswer.allCases.map(\.rawValue)
                + ["push", "other_push", "foreground", "pull", "changed", "unchanged", "failed"]
        )
        for (key, value) in event.properties {
            #expect(key.wholeMatch(of: /\$?[a-z_]+/) != nil)
            if case let .word(word) = value {
                #expect(allowed.contains(word), "\(event.name).\(key) = \(word)")
            }
        }
    }

    @Test func aPairingFailureDropsTheWorkersHost() {
        let code = PairingFailureCode(.unreachable(host: "pr-worker.octocat.workers.dev"))
        #expect(code == .unreachable)
        #expect(AnalyticsEvent.workerPairingFailed(code).properties == ["code": .word("unreachable")])
    }

    // MARK: - PRKit's events

    @Test func prKitsEventsAreMappedWithoutTheirContent() {
        let ref = PullRequestRef(repo: "acme/checkout", number: 7)
        #expect(AnalyticsEvent(.opened(ref)) == nil, "reported once its content shows")
        let report = PROpenReport(
            source: .push, cache: .miss, timeToContentMilliseconds: 950, networkMilliseconds: 610, decodeMilliseconds: 45
        )
        #expect(AnalyticsEvent(.contentShown(report))
            == .pullRequestOpened(.push, .miss, timeToContentMs: 950, networkMs: 610, decodeMs: 45))
        #expect(AnalyticsEvent(.contentShown(report))?.properties == [
            "source": .word("push"), "cache": .word("miss"), "time_to_content_ms": .number(950),
            "network_ms": .number(610), "decode_ms": .number(45),
        ])
        #expect(AnalyticsEvent(.writeRefused("Branch acme/secret is protected")) == .pullRequestWriteRefused)
        #expect(AnalyticsEvent(.reviewRequests(3)) == nil)
        #expect(AnalyticsEvent(.synced(.pull, .changed)) == .pullRequestsSynced(.pull, .changed))
        #expect(AnalyticsEvent(.synced(.foreground, .unchanged)) == .pullRequestsSynced(.foreground, .unchanged))
    }

    @Test func aFailedRequestSendsItsAreaAndStatusOrWhyThereWasNone() {
        #expect(AnalyticsEvent(.requestFailed(.feedback, .status(404))) == .requestFailed(.feedback, .status(404)))
        #expect(AnalyticsEvent.requestFailed(.feedback, .status(404)).properties == [
            "area": .word("feedback"), "failure": .word("status"), "status": .number(404),
        ])
        #expect(AnalyticsEvent.requestFailed(.diff, .offline).properties == [
            "area": .word("diff"), "failure": .word("offline"),
        ])
    }

    @Test func aPushesSyncIsReportedOnlyWhenItFails() {
        #expect(AnalyticsEvent(.synced(.silentPush, .changed)) == nil)
        #expect(AnalyticsEvent(.synced(.otherPush, .unchanged)) == nil)
        #expect(AnalyticsEvent(.synced(.silentPush, .failed)) == .pullRequestsSynced(.silentPush, .failed))
    }

    @Test func theHostPassesPRKitsEventsOn() {
        let sink = RecordingAnalytics()
        let host = PRHubPRHost(access: .offline, samples: nil, usage: Self.usage(sink))
        host.receive(.opened(PullRequestRef(repo: "acme/checkout", number: 7)))
        host.receive(.reviewRequests(2))
        host.receive(.writeRefused("no"))
        #expect(sink.events == [.pullRequestWriteRefused])
    }

    // MARK: - The switch in Settings

    @Test func sharingIsOnUntilTurnedOffAndThenNothingIsSent() {
        let sink = RecordingAnalytics()
        let defaults = Self.defaults()
        let usage = Self.usage(sink, defaults: defaults)
        #expect(usage.isSharing)
        usage.record(.signedOut)
        usage.setSharing(false)
        usage.record(.accountDeleted)
        #expect(sink.events == [.signedOut])
        #expect(sink.sharing == [false])
        #expect(!Self.usage(RecordingAnalytics(), defaults: defaults).isSharing)
    }

    @Test func turningSharingBackOnSendsAgain() {
        let sink = RecordingAnalytics()
        let usage = Self.usage(sink)
        usage.setSharing(false)
        usage.setSharing(true)
        usage.record(.samplesLeft)
        #expect(sink.sharing == [false, true])
        #expect(sink.events == [.samplesLeft])
    }

    @Test func theVendorStartsOptedOutWhenSharingWasTurnedOff() {
        let defaults = Self.defaults()
        defaults.set(false, forKey: UsageAnalytics.sharingKey)
        var startedSharing: Bool?
        _ = UsageAnalytics.make(
            project: Self.project, isDebugBuild: false, isRunningTests: false, defaults: defaults,
            vendor: { _, isSharing in
                startedSharing = isSharing
                return RecordingAnalytics()
            }
        )
        #expect(startedSharing == false)
    }

    // MARK: - No project, Debug and tests: off

    nonisolated static let project = AnalyticsProject(info: [
        "PRHubAnalyticsKey": "phc_example", "PRHubAnalyticsHost": "eu.i.posthog.com",
    ])

    @Test func theProjectComesFromInfoPlist() throws {
        let project = try #require(Self.project)
        #expect(project.apiKey == "phc_example")
        #expect(project.host == URL(string: "https://eu.i.posthog.com"))
    }

    @Test(arguments: [
        [:],
        ["PRHubAnalyticsKey": "", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": " ", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": "$(PRHUB_ANALYTICS_KEY)", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": "phc_example", "PRHubAnalyticsHost": ""],
    ])
    func anEmptyKeyOrHostNamesNoProject(_ info: [String: String]) {
        #expect(AnalyticsProject(info: info) == nil)
    }

    @Test func withoutAProjectNothingIsSentAndSettingsHasNoSwitch() {
        var made = false
        let usage = UsageAnalytics.make(
            project: nil, isDebugBuild: false, isRunningTests: false, defaults: Self.defaults(),
            vendor: { _, _ in
                made = true
                return RecordingAnalytics()
            }
        )
        usage.record(.signedOut)
        #expect(!made && !usage.hasProject)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func aDebugBuildOrATestRunSendsNothing(isDebugBuild: Bool, isRunningTests: Bool) {
        var made = false
        let usage = UsageAnalytics.make(
            project: Self.project, isDebugBuild: isDebugBuild, isRunningTests: isRunningTests,
            defaults: Self.defaults(),
            vendor: { _, _ in
                made = true
                return RecordingAnalytics()
            }
        )
        #expect(!made && usage.hasProject)
    }

    @Test func aReleaseBuildWithAProjectSends() {
        let sink = RecordingAnalytics()
        let usage = UsageAnalytics.make(
            project: Self.project, isDebugBuild: false, isRunningTests: false, defaults: Self.defaults(),
            vendor: { _, _ in sink }
        )
        usage.record(.workerPaired)
        #expect(sink.events == [.workerPaired])
    }

    // MARK: - Samples

    @Test func tryingAndLeavingTheSamplesIsRecorded() {
        let sink = RecordingAnalytics()
        let environment = PRHubEnvironment(connection: PRHubEnvironment.sample().connection, usage: Self.usage(sink))
        environment.startSample()
        #expect(environment.sample?.usage === environment.usage)
        environment.endSample()
        #expect(sink.events == [.onboardingPathChosen(.samples), .samplesLeft])
    }
}
