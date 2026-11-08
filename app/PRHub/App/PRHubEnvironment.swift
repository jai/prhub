import Foundation
import Observation

/// PRHub's composition root: the PR screens, the Worker they talk to, and the way in between. Every request goes to the
/// URL the setup link or Sign in with GitHub gave, with this phone's device secret or session secret as the bearer
/// (docs/api.md).
@MainActor
@Observable
final class PRHubEnvironment {
    static let shared = PRHubEnvironment(
        endpoint: .live, secrets: .live(isProtectedDataAvailable: AppIdentity.protectedDataAvailability()),
        usage: .live()
    )

    let connection: WorkerConnection
    let prs: PRKitController
    let navigation: PRHubNavigation
    /// Anonymous usage events, and Settings' switch for them.
    let usage: UsageAnalytics
    /// Runs on the bundled samples (`PRHubEnvironment.sample()`), with no Worker.
    let isSample: Bool
    /// "Try with sample PRs", while it is on: shown in place of onboarding until Connect your own Worker.
    private(set) var sample: PRHubEnvironment?
    /// Review alerts: whether they may show, and the one offer to turn them on.
    let alertPermission: PRHubAlertPermission
    /// Set as the notification center's delegate at launch (`AppDelegate`), which holds it weakly.
    @ObservationIgnored private(set) lazy var notificationDelegate = PRHubNotificationDelegate(
        open: { [weak self] ref in self?.openAlert(ref) },
        signedOut: { [weak self] in
            guard let self else {
                return
            }
            Task { await self.signedOutByGitHub() }
        }
    )

    init(
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, defaults: UserDefaults = .standard,
        alertPermission: PRHubAlertPermission = PRHubAlertPermission(), build: PRHubBuild = .current,
        authenticate: @escaping Authenticate = WebSignIn.live, usage: UsageAnalytics = .disabled()
    ) {
        self.alertPermission = alertPermission
        self.usage = usage
        let refusals = SessionRefusals()
        let host = PRHubPRHost(
            access: .paired(endpoint: endpoint, secret: { try secrets.loadOrCreate() }, refused: {
                await refusals.check()
            }),
            samples: nil, usage: usage
        )
        prs = PRKitController(host: host)
        connection = Self.makeConnection(
            endpoint: endpoint, secrets: secrets, defaults: defaults, build: build, authenticate: authenticate,
            usage: usage, unpair: { [client = prs.client] in try? await client.unpair() }
        )
        refusals.connection = connection
        navigation = PRHubNavigation(pullRequests: prs)
        isSample = false
        let connection = connection
        host.config = { connection.config }
    }

    /// Over `access` (none: nothing is sent) and, for "Try with sample PRs", `samples`.
    init(
        connection: WorkerConnection, access: PRViewerAccess = .offline, samples: PRSampleSet? = nil,
        isSample: Bool = false, alertPermission: PRHubAlertPermission = PRHubAlertPermission(),
        usage: UsageAnalytics = .disabled()
    ) {
        self.alertPermission = alertPermission
        self.usage = usage
        let host = PRHubPRHost(access: access, samples: samples, usage: usage)
        self.connection = connection
        prs = PRKitController(host: host)
        self.isSample = isSample
        navigation = PRHubNavigation(pullRequests: prs)
        host.config = { connection.config }
    }

    /// Pairing posts the code to the setup link's Worker once, and never retries: a code is single use. A pr-worker
    /// admits the secret at once; the first config read follows (`WorkerConnection.connect`). Sign in with GitHub
    /// goes to the build's hosted Worker (`PRHubBuild.hostedURL`), and keeps the session secret where the device
    /// secret goes.
    static func makeConnection(
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, defaults: UserDefaults, build: PRHubBuild,
        authenticate: @escaping Authenticate, usage: UsageAnalytics = .disabled(),
        unpair: (@Sendable () async -> Void)? = nil
    ) -> WorkerConnection {
        let pairing = DevicePairing(
            pair: { worker, code in
                try await PairingClient(secret: { try secrets.loadOrCreate() }).pair(worker: worker, code: code)
            },
            save: { try endpoint.save($0) }
        )
        let account = AccountClient(worker: { endpoint.url }, bearer: { try secrets.loadOrCreate() })
        return WorkerConnection(
            endpoint: endpoint, pairing: pairing,
            fetchConfig: { try await account.deviceConfig() },
            forgetSecret: { try secrets.delete() },
            unpair: unpair,
            defaults: defaults, build: build, usage: usage,
            hosted: build.hostedURL.map { worker in
                .live(worker: worker, account: account, authenticate: authenticate, secrets: secrets)
            }
        )
    }

    /// Onboarding's "Try with sample PRs".
    func startSample() {
        usage.record(.onboardingPathChosen(.samples))
        sample = .sample(usage: usage)
    }

    /// Settings' "Connect your own Worker", or a setup link opened during the samples: back to onboarding, with no
    /// list setting of the samples' left behind.
    func endSample() {
        usage.record(.samplesLeft)
        sample = nil
        PRSampleSet.resetListSettings()
    }

    /// Settings' Disconnect: the Worker forgets this phone, the phone forgets the Worker and every PR it mirrored, so
    /// the next Worker starts from nothing.
    func disconnect() async {
        await connection.disconnect()
        forgetLocalData()
    }

    /// Sign in with GitHub, from onboarding or Sign in again. Another account than the last one starts from nothing.
    func signIn() async {
        guard let outcome = await connection.signIn() else {
            return
        }
        if outcome == .newPerson {
            prs.forgetEverything()
        }
    }

    /// Settings' Sign out, or Sign in again's: the session ends, and the phone forgets every PR it mirrored.
    func signOut() async {
        await connection.signOut()
        forgetLocalData()
    }

    /// Settings' Delete Account: the Worker deletes the account and revokes PRHub on GitHub; the phone forgets it all.
    func deleteAccount() async throws(AccountActionError) {
        try await connection.deleteAccount()
        forgetLocalData()
    }

    /// The `signed_out` push.
    func signedOutByGitHub() async {
        await connection.signedOutByGitHub()
    }

    private func forgetLocalData() {
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
        guard !connection.needsSignInAgain else {
            return
        }
        // The sync sends this launch's push token too, when the Worker pushes.
        await prs.refresh(.foreground)
        await offerAlertsIfDue()
    }
}

/// The PR screens' `401`s, to the connection: on the hosted Worker one means signed out, or a session it forgot.
@MainActor
final class SessionRefusals {
    weak var connection: WorkerConnection?

    func check() async {
        await connection?.checkSession()
    }
}

extension WorkerConnection.Hosted {
    /// The hosted Worker's routes over `account`, with the app's sign-in sheet.
    static func live(
        worker: URL, account: AccountClient, authenticate: @escaping Authenticate, secrets: DeviceSecretStore
    ) -> Self {
        var finishing = account
        // `finish` goes to the hosted Worker whatever the phone saved before.
        finishing.worker = { worker }
        let signIn = HostedSignIn(worker: worker, authenticate: authenticate) { [finishing] code, verifier in
            try await finishing.finish(code: code, verifier: verifier)
        }
        return Self(
            worker: worker,
            signIn: { try await signIn.run() },
            saveSecret: { try secrets.save($0) },
            signOut: { try await account.signOut() },
            deleteAccount: { _ = try await account.deleteAccount() },
            setAnthropicKey: { _ = try await account.setAnthropicKey($0) },
            removeAnthropicKey: { try await account.removeAnthropicKey() }
        )
    }
}
