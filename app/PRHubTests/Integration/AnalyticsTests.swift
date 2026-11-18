import Foundation
@testable import PRHubCore
import Testing

/// Analytics preferences and host integration; vendors are replaced with a recording sink.
@MainActor
struct AnalyticsTests {
    private let resources = IntegrationResources()
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

    @Test func theHostPassesPRKitsEventsOn() {
        let sink = RecordingAnalytics()
        let host = PRHubPRHost(access: .offline, samples: nil, usage: resources.usage(sink))
        host.receive(.opened(PullRequestRef(repo: "acme/checkout", number: 7)))
        host.receive(.reviewRequests(2))
        host.receive(.writeRefused("no"))
        #expect(sink.events == [.pullRequestWriteRefused])
    }

    @Test func aRepeatingFailureIsSentOnceAMinute() {
        let sink = RecordingAnalytics()
        let usage = resources.usage(sink)
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
        let defaults = resources.defaults()
        let usage = UsageAnalytics(hasProject: true, sink: sink, defaults: defaults)
        #expect(usage.isSharing)
        usage.record(.signedOut)
        usage.setSharing(false)
        usage.record(.accountDeleted)
        #expect(sink.events == [.signedOut])
        #expect(sink.sharing == [false])
        #expect(!UsageAnalytics(hasProject: true, sink: RecordingAnalytics(), defaults: defaults).isSharing)
    }

    @Test func turningSharingBackOnSendsAgain() {
        let sink = RecordingAnalytics()
        let usage = resources.usage(sink)
        usage.setSharing(false)
        usage.setSharing(true)
        usage.record(.samplesLeft)
        #expect(sink.sharing == [false, true])
        #expect(sink.events == [.samplesLeft])
    }

    @Test func theVendorStartsOptedOutWhenSharingWasTurnedOff() {
        let defaults = resources.defaults()
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
            project: nil, isDebugBuild: false, isRunningTests: false, defaults: resources.defaults(),
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
            defaults: resources.defaults(),
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
            project: Self.project, isDebugBuild: false, isRunningTests: false, defaults: resources.defaults(),
            vendor: { _, _ in sink }
        )
        usage.record(.workerPaired)
        #expect(sink.events == [.workerPaired])
    }

    @Test func aScanThatCannotOpenTheCameraSaysWhy() throws {
        let sink = RecordingAnalytics()
        let connection = try WorkerConnection(
            endpoint: WorkerEndpoint(fixed: #require(URL(string: "https://worker.example"))),
            pairing: DevicePairing(pair: { _, _ in throw URLError(.badURL) }, save: { _ in }),
            fetchConfig: { _ in throw URLError(.badURL) }, forgetSecret: {}, defaults: resources.defaults(),
            usage: resources.usage(sink)
        )
        connection.scanUnavailable(.cameraOff)
        connection.scanUnavailable(.unsupported)
        #expect(sink.events == [.setupScanUnavailable(.cameraOff), .setupScanUnavailable(.unsupported)])
    }

    // MARK: - Samples

    @Test func tryingAndLeavingTheSamplesIsRecorded() {
        let sink = RecordingAnalytics()
        let environment = resources.environment(usage: resources.usage(sink))
        environment.startSample()
        #expect(environment.sample?.usage === environment.usage)
        environment.endSample()
        #expect(sink.events == [.onboardingPathChosen(.samples), .samplesLeft])
    }
}
