import DurableNetworking
import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

/// What a relaunch finds on disk and in the preferences: the PRs read online, opened again with no network; the choice
/// to stop sharing usage; a build Later skipped. Each relaunch is a new object over the same folder and preferences.
@MainActor
struct PRHubRelaunchTests {
    private let resources = IntegrationResources()
    private nonisolated static let worker = URL(string: "https://stub-worker.invalid")!
    private static let build = PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: true, samples: true)

    /// PRHub over `PRHubStubWorker`'s stand-in Worker, answering from the sample PRs, with everything on disk.
    private func launch(directory: URL, defaults: UserDefaults, staging: URL, isOnline: Bool) -> PRHubEnvironment {
        let transport = PRHubStubWorker.Transport(samples: .prHub, staging: staging, isOffline: !isOnline)
        return PRHubEnvironment.offline(
            config: DeviceConfig(features: [.askAI, .keyLines], login: PRSampleSet.prHubLogin),
            access: PRViewerAccess(baseURL: { Self.worker }, bearer: { "stub" }, discard: {}), worker: Self.worker,
            isSample: false, usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults),
            transport: transport,
            storage: .onDisk(directory: directory, defaults: defaults, sampleConfiguration: resources.defaults()),
            build: Self.build, alertPermission: resources.alertPermission(defaults: defaults),
            network: PRNetwork(isOnline: isOnline)
        )
    }

    /// The real path: the PRs load from the Worker into the mirror, the app is quit, and it opens again with no
    /// network on what it saved: the list, and a PR's page.
    @Test func whatLoadedOnlineOpensAgainOfflineAfterARelaunch() async throws {
        let directory = resources.directory()
        let defaults = resources.defaults()
        let staging = resources.directory("staging")
        _ = PRSampleSet.prHub.seed(in: staging, defaults: resources.defaults())

        let online = launch(directory: directory, defaults: defaults, staging: staging, isOnline: true)
        #expect(online.prs.model.rows.isEmpty, "nothing on the phone before the first read")
        #expect(await online.prs.model.refresh(.foreground) == .changed)
        let listed = online.prs.model.rows.map(\.id)
        #expect(listed.contains("acme/web#412"))

        let offline = launch(directory: directory, defaults: defaults, staging: staging, isOnline: false)
        #expect(offline.prs.model.rows.map(\.id) == listed, "the saved PRs, with no network")
        let row = try #require(offline.prs.model.rows.first { $0.id == "acme/web#412" })
        let page = offline.prs.model.session(for: row)
        #expect(page.content?.detail.title == row.title, "the saved PR's page, with nothing read")
        #expect(!page.isNotSavedOffline)
    }

    @Test func theChoiceToStopSharingUsageSurvivesARelaunch() {
        let defaults = resources.defaults()
        let usage = UsageAnalytics(hasProject: true, sink: nil, defaults: defaults)
        #expect(usage.isSharing, "on until turned off")
        usage.setSharing(false)

        var vendorStartedSharing: Bool?
        let relaunched = UsageAnalytics.make(
            project: AnalyticsProject(info: ["PRHubAnalyticsKey": "phc_example", "PRHubAnalyticsHost": "eu.i.posthog.com"]),
            isDebugBuild: false, isRunningTests: false, defaults: defaults,
            vendor: { _, isSharing in
                vendorStartedSharing = isSharing
                return SilentVendor()
            }
        )
        #expect(!relaunched.isSharing)
        #expect(vendorStartedSharing == false, "the vendor starts opted out")
    }

    @Test func laterSkipsThatBuildAcrossRelaunchesAndANewerOneIsOfferedAgain() {
        let defaults = resources.defaults()
        let running = AppBuild(version: "1.0", build: "200")
        func launch() -> PRHubUpdate {
            PRHubUpdate(running: running, defaults: defaults, isEnabled: true, usage: resources.usage())
        }
        func config(_ build: String) -> DeviceConfig {
            DeviceConfig(features: [], appLatest: DeviceConfig.AppLatest(public: AppBuild(version: "1.0", build: build)))
        }
        let first = launch()
        first.check(config("201"))
        #expect(first.offered?.build == "201")
        first.later()

        let second = launch()
        second.check(config("201"))
        #expect(second.offered == nil, "Later skips that build")

        let third = launch()
        third.check(config("202"))
        #expect(third.offered?.build == "202", "a build newer than the one skipped is offered")
    }
}

/// A vendor that keeps nothing.
@MainActor
private final class SilentVendor: Analytics {
    func record(_: AnalyticsEvent) {}
    func setSharing(_: Bool) {}
}
