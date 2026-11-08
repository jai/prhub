// Every file of the app reads PRKit's types (the PR screens, their models and the design parts) without its own import.
@_exported import PRKit
import Foundation

/// PRHub's side of the PR screens (`PRKitHost`): the pr-worker it paired with, the features that Worker's
/// `GET /device/config` serves, and no outbox: a write goes to the Worker or not at all.
@MainActor
final class PRHubPRHost: PRKitHost {
    let access: PRViewerAccess
    let samples: PRSampleSet?
    let usage: UsageAnalytics
    /// The connection's config, read through: a new config shows at once. `nil` before the first read.
    var config: @MainActor () -> DeviceConfig? = { nil }

    init(access: PRViewerAccess, samples: PRSampleSet?, usage: UsageAnalytics) {
        self.access = access
        self.samples = samples
        self.usage = usage
    }

    func isInForeground() async -> Bool { appIsInForeground() }

    var configuration: PRKitConfiguration {
        Self.configuration(config())
    }

    /// What the PR screens follow of a Worker's config: its features, its `orgs` as the filter's default (else every
    /// owner), its login, and on the hosted Worker the empty list's pointer to where the GitHub App is missing.
    static func configuration(_ config: DeviceConfig?) -> PRKitConfiguration {
        let all: [PRKitConfiguration.Feature: DeviceFeature] = [
            .askAI: .askAI, .keyLines: .keyLines, .rewrite: .rewrite, .push: .push,
        ]
        return PRKitConfiguration(
            features: Set(all.filter { config?.isOn($0.value) == true }.keys),
            orgDefault: .following(orgs: config?.orgs),
            login: config?.login,
            emptyHint: config.flatMap { $0.hosted ? installHint($0) : nil }
        )
    }

    /// The hosted Worker sees only repos where the PRHub App is installed, so an empty list says where it is and
    /// where it is missing: on no account, suspended, or not on the person's own.
    static func installHint(_ config: DeviceConfig) -> PREmptyHint {
        guard let installations = config.installations else {
            return genericInstallHint
        }
        let active = installations.filter { !$0.suspended }
        let suspended = installations.filter(\.suspended)
        if installations.isEmpty {
            return PREmptyHint(
                title: "PRHub isn't installed yet",
                message: "PRHub sees pull requests where its GitHub App is installed, and it isn't on any of your "
                    + "accounts yet. Install it on your own account or an org; an org owner installs it, a member can "
                    + "ask for it.",
                linkTitle: "Install PRHub App",
                link: PRHubBuild.appInstallURL
            )
        }
        if active.isEmpty, let first = suspended.first {
            return PREmptyHint(
                title: "PRHub is suspended",
                message: "The PRHub App is suspended on \(names(suspended)), so PRHub sees no pull requests there. An "
                    + "owner can unsuspend it in the installation's settings on GitHub.",
                linkTitle: "Open \(first.account) on GitHub",
                link: first.settingsURL
            )
        }
        let login = config.account?.login ?? config.login
        let ownMissing = login.flatMap { login in
            installations.contains { $0.accountType == .user && $0.account.lowercased() == login.lowercased() }
                ? nil : login
        }
        let missing = [
            ownMissing.map { "It isn't installed on your own account, \($0)." },
            suspended.isEmpty ? nil : "It's suspended on \(names(suspended)).",
        ].compactMap(\.self)
        let installed = "None of your pull requests or review requests are open in \(names(active)), where PRHub is "
            + "installed."
        return PREmptyHint(
            title: "No PRs yet",
            message: ([installed] + missing).joined(separator: " "),
            linkTitle: "Add another account",
            link: PRHubBuild.appInstallURL
        )
    }

    /// "acme", "acme and globex", "acme, globex, and initech".
    private static func names(_ installations: [GitHubInstallation]) -> String {
        installations.map(\.account).formatted(.list(type: .and))
    }

    /// Before the Worker has read where the App is installed.
    static let genericInstallHint = PREmptyHint(
        title: "No PRs yet",
        message: "PRHub sees pull requests in orgs and accounts where the PRHub GitHub App is installed. An org owner "
            + "installs it; a member can ask for it.",
        linkTitle: "Install PRHub App on your orgs",
        link: PRHubBuild.appInstallURL
    )

    var outbox: (any PRKitOutbox)? { nil }
    var apnsEnvironment: String { APNSEnvironment.current() }
    var launchOptions: PRKitLaunchOptions { .none }
    func receive(_ event: PRKitEvent) {
        if let event = AnalyticsEvent(event) {
            usage.record(event)
        }
    }
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
