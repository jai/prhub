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
    /// owner), and its login.
    static func configuration(_ config: DeviceConfig?) -> PRKitConfiguration {
        let all: [PRKitConfiguration.Feature: DeviceFeature] = [
            .askAI: .askAI, .keyLines: .keyLines, .rewrite: .rewrite, .push: .push,
        ]
        return PRKitConfiguration(
            features: Set(all.filter { config?.isOn($0.value) == true }.keys),
            orgDefault: .following(orgs: config?.orgs),
            login: config?.login
        )
    }

    var outbox: (any PRKitOutbox)? { nil }
    var apnsEnvironment: String { APNSEnvironment.current() }
    var launchOptions: PRKitLaunchOptions { .none }
    func receive(_ event: PRKitEvent) {}
    /// PRHub has no event log: the system log has it (`PRMirror`).
    func log(_ line: String) {}
}

extension PRViewerAccess {
    /// The paired pr-worker, with this phone's device secret as the bearer.
    static func paired(endpoint: WorkerEndpoint, secret: @escaping @Sendable () throws -> String) -> PRViewerAccess {
        PRViewerAccess(baseURL: { endpoint.url }, bearer: { try secret() }, discard: {})
    }
}

extension PRViewerClient {
    /// A client over the app's transport, which waits for a network while someone is looking at the app.
    init(access: PRViewerAccess) {
        self.init(access: access, isInForeground: { await appIsInForeground() })
    }

    /// `GET /device/config`: what the pr-worker serves (docs/api.md).
    func deviceConfig() async throws -> DeviceConfig {
        try await read("device/config", as: DeviceConfig.self)
    }

    /// `DELETE /device/pair`: the Worker forgets this secret. `204`.
    func unpair() async throws {
        try await delete("device/pair")
    }
}
