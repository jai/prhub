#if DEBUG
import Foundation

/// Debug builds only: the launch arguments the UI tests use to put PRHub on screen with no Worker.
/// - `-PRHubFirstRun`: onboarding, as on a new phone, with a pairing that is always refused.
/// - `-PRHubPaired`: the PRs and Settings over the sample PRs as if paired, every AI feature on. With `-PRHubNoAI` the
///   Worker has no model key; with `-PRHubSettings` it opens on Settings; with `-PRHubLongDiff` For review starts with a
///   PR whose one file is longer than the screen, for the diff's bars.
enum PRHubScreenshots {
    @MainActor static func environment() -> PRHubEnvironment? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-PRHubFirstRun") {
            return firstRun()
        }
        guard arguments.contains("-PRHubPaired") else {
            return nil
        }
        let features: Set<DeviceFeature> = arguments.contains("-PRHubNoAI")
            ? [.push] : [.askAI, .keyLines, .rewrite, .push]
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: features, login: PRSampleSet.prHubLogin),
            samples: arguments.contains("-PRHubLongDiff") ? .prHubLongDiff : .prHub,
            worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "screenshots-paired",
            isSample: false
        )
        if arguments.contains("-PRHubSettings") {
            environment.navigation.selectedTab = .settings
        }
        return environment
    }

    @MainActor private static func firstRun() -> PRHubEnvironment {
        let store = WorkerURLStore(service: AppIdentity.bundleID + ".screenshots-first-run", account: "url")
        let endpoint = WorkerEndpoint(store: store)
        try? endpoint.clear()
        let defaults = UserDefaults(suiteName: "screenshots-first-run") ?? .standard
        defaults.removePersistentDomain(forName: "screenshots-first-run")
        let connection = WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(
                pair: { _, _ in throw PairingClient.Failure.server("pairing_code_invalid", 401) },
                save: { _ in }
            ),
            fetchConfig: { DeviceConfig(features: []) }, forgetSecret: {}, defaults: defaults
        )
        return PRHubEnvironment(connection: connection)
    }
}

extension PRSampleSet {
    /// The samples, with one more PR first on For review: one file, longer than any phone's screen.
    static let prHubLongDiff = PRSampleSet(
        samples: [longDiff] + prHub.samples, mergedReviewed: [], mergedMine: [], answersOnPhone: true
    )

    private static let longDiffMembers = (1...30).map { "member_\($0)" }

    private static let longDiff = PRHubSample(
        repo: "acme/infra", number: 31, title: "Give the deploy team access to staging", list: "review",
        author: "mona", checks: "passing", review: "required", merge: "clean",
        body: "Adds an access membership for each of the deploy team.",
        diff: """
        diff --git a/zero-trust/access_memberships.tf b/zero-trust/access_memberships.tf
        --- /dev/null
        +++ b/zero-trust/access_memberships.tf
        @@ -0,0 +1,\(longDiffMembers.count * 5) @@

        """ + longDiffMembers.map { name in
            "+resource \"access_membership\" \"\(name)\" {\n+  group  = \"deploy\"\n+  member = \"\(name)\"\n+}\n+\n"
        }.joined(),
        keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil
    ).sample
}
#endif
