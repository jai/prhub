import Foundation
@testable import PRHubCore
import Testing

/// Analytics preferences and host integration; vendors are replaced with a recording sink.
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

    @Test func theHostPassesPRKitsEventsOn() {
        let sink = RecordingAnalytics()
        let host = PRHubPRHost(access: .offline, samples: nil, usage: Self.usage(sink))
        host.receive(.opened(PullRequestRef(repo: "acme/checkout", number: 7)))
        host.receive(.reviewRequests(2))
        host.receive(.writeRefused("no"))
        #expect(sink.events == [.pullRequestWriteRefused])
    }

    @Test func aRepeatingFailureIsSentOnceAMinute() {
        let sink = RecordingAnalytics()
        let usage = Self.usage(sink)
        var time = Date(timeIntervalSince1970: 1000)
        usage.now = { time }
        let offline = AnalyticsEvent.pullRequestWrote(.merge, .failed(.offline))
        usage.record(offline)
        usage.record(offline)
        usage.record(.pullRequestWrote(.merge, .failed(.timeout)))
        usage.record(.pullRequestWrote(.merge, .done))
        usage.record(.pullRequestWrote(.merge, .done))
        time += UsageAnalytics.failureWindow
        usage.record(offline)
        #expect(sink.events == [
            offline, .pullRequestWrote(.merge, .failed(.timeout)), .pullRequestWrote(.merge, .done),
            .pullRequestWrote(.merge, .done), offline,
        ])
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
