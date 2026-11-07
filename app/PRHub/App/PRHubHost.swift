// Every file of the app reads PRKit's types (the PR screens, their models and the design parts) without its own import.
@_exported import PRKit
import Foundation

/// PRHub's side of the PR screens (`PRKitHost`): the pr-worker it paired with, the features that Worker's
/// `GET /device/config` serves, and no outbox: a write goes to the Worker or not at all.
@MainActor
final class PRHubPRHost: PRKitHost {
    let access: PRViewerAccess
    let samples: PRSampleSet?
    /// The connection's config, read through: a new config shows at once. `nil` before the first read.
    var config: @MainActor () -> DeviceConfig? = { nil }

    init(access: PRViewerAccess, samples: PRSampleSet?) {
        self.access = access
        self.samples = samples
    }

    func isInForeground() async -> Bool { appIsInForeground() }

    var configuration: PRKitConfiguration {
        Self.configuration(config())
    }

    /// What the PR screens follow of a Worker's config: its features, its `orgs` as the filter's default (else every
    /// owner), its login, and on the hosted Worker the empty list's pointer to installing the GitHub App.
    static func configuration(_ config: DeviceConfig?) -> PRKitConfiguration {
        let all: [PRKitConfiguration.Feature: DeviceFeature] = [
            .askAI: .askAI, .keyLines: .keyLines, .rewrite: .rewrite, .push: .push,
        ]
        return PRKitConfiguration(
            features: Set(all.filter { config?.isOn($0.value) == true }.keys),
            orgDefault: .following(orgs: config?.orgs),
            login: config?.login,
            emptyHint: config?.hosted == true ? installHint : nil
        )
    }

    /// The hosted Worker sees only repos where the PRHub App is installed, so an empty list most often means none is.
    // TODO: name the orgs without the App once `GET /device/config` says which (docs/plans/github-app.md, step 7).
    static let installHint = PREmptyHint(
        title: "No PRs yet",
        message: "PRHub sees pull requests in orgs and accounts where the PRHub GitHub App is installed. An org owner "
            + "installs it; a member can ask for it.",
        linkTitle: "Install PRHub App on your orgs",
        link: PRHubBuild.appInstallURL
    )

    var outbox: (any PRKitOutbox)? { nil }
    var apnsEnvironment: String { APNSEnvironment.current() }
    var launchOptions: PRKitLaunchOptions { .none }
    func receive(_ event: PRKitEvent) {}
    /// PRHub has no event log: the system log has it (`PRMirror`).
    func log(_ line: String) {}
}

extension PRViewerAccess {
    /// The paired pr-worker or the hosted Worker, with this phone's secret as the bearer. `refused` hears each `401`.
    static func paired(
        endpoint: WorkerEndpoint, secret: @escaping @Sendable () throws -> String,
        refused: @escaping @Sendable () async -> Void = {}
    ) -> PRViewerAccess {
        PRViewerAccess(baseURL: { endpoint.url }, bearer: { try secret() }, discard: refused)
    }
}

extension PRViewerClient {
    /// A client over the app's transport, which waits for a network while someone is looking at the app.
    init(access: PRViewerAccess) {
        self.init(access: access, isInForeground: { await appIsInForeground() })
    }

    /// `DELETE /device/pair`: the Worker forgets this secret. `204`.
    func unpair() async throws {
        try await delete("device/pair")
    }
}
