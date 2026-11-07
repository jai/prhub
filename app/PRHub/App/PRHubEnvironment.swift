import Foundation
import Observation

/// PRHub's composition root: the PR screens, the pr-worker they talk to, and the pairing in between. Every request goes
/// to the URL the setup link gave, with this phone's device secret as the bearer (docs/api.md).
@MainActor
@Observable
final class PRHubEnvironment {
    static let shared = PRHubEnvironment(endpoint: .live, secrets: .live(
        isProtectedDataAvailable: AppIdentity.protectedDataAvailability()
    ))

    let connection: WorkerConnection
    let prs: PRKitController
    let navigation: PRHubNavigation
    /// Runs on the bundled samples (`PRHubEnvironment.sample()`), with no Worker.
    let isSample: Bool
    /// "Try with sample PRs", while it is on: shown in place of onboarding until Connect your own Worker.
    private(set) var sample: PRHubEnvironment?
    /// Review alerts: whether they may show, and the one offer to turn them on.
    let alertPermission: PRHubAlertPermission
    /// Set as the notification center's delegate at launch (`AppDelegate`), which holds it weakly.
    @ObservationIgnored private(set) lazy var notificationDelegate = PRHubNotificationDelegate { [weak self] ref in
        self?.openAlert(ref)
    }

    init(
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, defaults: UserDefaults = .standard,
        alertPermission: PRHubAlertPermission = PRHubAlertPermission()
    ) {
        self.alertPermission = alertPermission
        let host = PRHubPRHost(
            access: .paired(endpoint: endpoint, secret: { try secrets.loadOrCreate() }), samples: nil
        )
        prs = PRKitController(host: host)
        connection = Self.makeConnection(endpoint: endpoint, secrets: secrets, client: prs.client, defaults: defaults)
        navigation = PRHubNavigation(pullRequests: prs)
        isSample = false
        let connection = connection
        host.config = { connection.config }
    }

    /// Over `access` (none: nothing is sent) and, for "Try with sample PRs", `samples`.
    init(
        connection: WorkerConnection, access: PRViewerAccess = .offline, samples: PRSampleSet? = nil,
        isSample: Bool = false, alertPermission: PRHubAlertPermission = PRHubAlertPermission()
    ) {
        self.alertPermission = alertPermission
        let host = PRHubPRHost(access: access, samples: samples)
        self.connection = connection
        prs = PRKitController(host: host)
        self.isSample = isSample
        navigation = PRHubNavigation(pullRequests: prs)
        host.config = { connection.config }
    }

    /// Pairing posts the code to the setup link's Worker once, and never retries: a code is single use. A pr-worker
    /// admits the secret at once; the first config read follows (`WorkerConnection.connect`).
    static func makeConnection(
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, client: PRViewerClient, defaults: UserDefaults
    ) -> WorkerConnection {
        let pairing = DevicePairing(
            pair: { worker, code in
                try await PairingClient(secret: { try secrets.loadOrCreate() }).pair(worker: worker, code: code)
            },
            save: { try endpoint.save($0) }
        )
        return WorkerConnection(
            endpoint: endpoint, pairing: pairing,
            fetchConfig: { try await client.deviceConfig() },
            forgetSecret: { try secrets.delete() },
            unpair: { try? await client.unpair() },
            defaults: defaults
        )
    }

    /// Onboarding's "Try with sample PRs".
    func startSample() {
        sample = .sample()
    }

    /// Settings' "Connect your own Worker", or a setup link opened during the samples: back to onboarding, with no
    /// list setting of the samples' left behind.
    func endSample() {
        sample = nil
        PRSampleSet.resetListSettings()
    }

    /// Settings' Disconnect: the Worker forgets this phone, the phone forgets the Worker and every PR it mirrored, so
    /// the next Worker starts from nothing.
    func disconnect() async {
        await connection.disconnect()
        guard !connection.isPaired else {
            return
        }
        prs.forgetEverything()
        alertPermission.forgetDecline()
    }

    /// A tapped review alert: its PR on the PRs tab. Nothing while no Worker is paired, as during the samples.
    func openAlert(_ ref: PullRequestRef) {
        guard connection.isPaired, sample == nil else {
            return
        }
        navigation.showPullRequest(ref)
    }

    /// Just paired, or a config read: offers alerts once the Worker pushes.
    func offerAlertsIfDue() async {
        guard !isSample, connection.isPaired, !connection.showsOnboarding else {
            return
        }
        await alertPermission.offerIfDue(workerPushes: connection.config?.isOn(.push) == true)
    }

    /// Launch, and every foreground: the Keychain again (a launch before the first unlock reads nothing), the
    /// config, then the list.
    func becameActive() async {
        connection.reload()
        guard connection.isPaired, !connection.showsOnboarding else {
            return
        }
        await connection.refreshConfig()
        // The sync sends this launch's push token too, when the Worker pushes.
        await prs.refresh(.foreground)
        await offerAlertsIfDue()
    }
}
