import DurableNetworking
import FeatureKit
import Foundation
import Observation
import PRKit

/// PRHub's composition root: the PR screens, the Worker they talk to, and the way in between. Every request goes to the
/// URL the setup link or Sign in with GitHub gave, with this phone's device secret or session secret as the bearer
/// (docs/api.md).
@MainActor
@Observable
public final class PRHubEnvironment {
    public static func live(usage: UsageAnalytics, testFlightGroup: TestFlightGroup) -> PRHubEnvironment {
        PRHubEnvironment(
            endpoint: .live, secrets: .live(isProtectedDataAvailable: AppIdentity.protectedDataAvailability()),
            usage: usage, testFlightGroup: testFlightGroup
        )
    }

    public let connection: WorkerConnection
    public let prs: PRKitController
    /// PR writes and questions saved on the device until the Worker has them. None for the samples or a check.
    @ObservationIgnored let outbox: PRHubOutbox?
    public let navigation: PRHubNavigation
    /// The Feedback tab's requests, over the PR screens' connection. Kept for the app's life, so drafts outlive the tab.
    /// The Feedback tab's: on FeedbackKit's direct path while the Worker's config names one, else through the Worker
    /// (`followFeedbackPath`).
    public private(set) var feedback: FeatureRequestsModel
    /// The FeedbackKit root `feedback` is on; nil through the Worker.
    @ObservationIgnored private var feedbackRoot: URL?
    @ObservationIgnored private var feedbackTokens: PRHubFeedbackTokens?
    /// Anonymous usage events, and Settings' switch for them.
    public let usage: UsageAnalytics
    @ObservationIgnored private let defaults: UserDefaults
    /// Runs on the bundled samples (`PRHubEnvironment.sample()`), with no Worker.
    public let isSample: Bool
    /// "Try with sample PRs", while it is on: shown in place of onboarding until Connect your own Worker.
    public private(set) var sample: PRHubEnvironment?
    /// Review alerts: whether they may show, and the one offer to turn them on.
    public let alertPermission: PRHubAlertPermission
    /// Update available, when TestFlight has a newer build than this one.
    public let update: PRHubUpdate
    #if os(iOS)
        /// The battery soak's MetricKit reports, when the Worker asks for them. None for the samples, a check or a test.
        @ObservationIgnored let metricKit: PRHubMetricKit?
    #endif
    /// Set as the notification center's delegate at launch (`AppDelegate`), which holds it weakly.
    @ObservationIgnored public private(set) lazy var notificationDelegate = PRHubNotificationDelegate(
        open: { [weak self] ref, row in self?.openAlert(ref, row: row) },
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
        authenticate: @escaping Authenticate = WebSignIn.live, usage: UsageAnalytics = .disabled(),
        testFlightGroup: TestFlightGroup = .public
    ) {
        self.alertPermission = alertPermission
        update = PRHubUpdate(group: testFlightGroup, defaults: defaults, usage: usage)
        self.usage = usage
        self.defaults = defaults
        let refusals = SessionRefusals()
        let host = PRHubPRHost(
            access: .paired(endpoint: endpoint, secret: { try secrets.loadOrCreate() }, refused: {
                await refusals.check()
            }),
            samples: nil, usage: usage
        )
        prs = PRKitController(host: host, defaults: defaults)
        let outbox = PRHubOutbox(client: prs.client)
        host.outbox = outbox
        outbox.kit = prs
        outbox.start()
        self.outbox = outbox
        connection = Self.makeConnection(
            endpoint: endpoint, secrets: secrets, defaults: defaults, build: build, authenticate: authenticate,
            usage: usage, unpair: { [client = prs.client] in try? await client.unpair() }
        )
        refusals.connection = connection
        navigation = PRHubNavigation(pullRequests: prs)
        let tokens = PRHubFeedbackTokens(client: prs.client)
        feedbackTokens = tokens
        let root = connection.config?.feedbackDirect?.url
        feedbackRoot = root
        feedback = FeatureRequestsModel(client: Self.feedbackClient(prs: prs, root: root, tokens: tokens))
        isSample = false
        let connection = connection
        host.config = { connection.config }
        host.isCheckingInstallations = { connection.isCheckingInstallations }
        host.leavesForGitHub = { connection.leavesForGitHub($0) }
        #if os(iOS)
            let reports = PRHubMetricReports(directory: Self.metricKitDirectory) { [client = prs.client] report in
                try await client.post("device/metrics", report)
            }
            metricKit = AppIdentity.isRunningTests ? nil : PRHubMetricKit(reports: reports)
            // The config as last read: MetricKit hands its payloads early in a launch, a wake's too.
            metricKit?.update(isOn: connection.config?.metricKit == true)
        #endif
    }

    /// Over `access` (none: nothing is sent) and, for "Try with sample PRs", `samples`.
    init(
        connection: WorkerConnection, access: PRViewerAccess = .offline, samples: PRSampleSet? = nil,
        isSample: Bool = false, alertPermission: PRHubAlertPermission = PRHubAlertPermission(),
        usage: UsageAnalytics = .disabled(), outbox: (any PRKitOutbox)? = nil, update: PRHubUpdate? = nil,
        transport: (any HTTPTransport)? = nil, defaults: UserDefaults = .standard
    ) {
        self.alertPermission = alertPermission
        self.update = update ?? PRHubUpdate()
        self.usage = usage
        self.defaults = defaults
        let host = PRHubPRHost(access: access, samples: samples, usage: usage)
        host.outbox = outbox
        host.transportOverride = transport
        self.connection = connection
        prs = PRKitController(host: host, defaults: defaults)
        self.outbox = nil
        self.isSample = isSample
        navigation = PRHubNavigation(pullRequests: prs)
        feedback = FeatureRequestsModel(client: FeatureClient(viewer: prs.client))
        #if os(iOS)
            metricKit = nil
        #endif
        host.config = { connection.config }
        host.isCheckingInstallations = { connection.isCheckingInstallations }
        host.leavesForGitHub = { connection.leavesForGitHub($0) }
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
            fetchConfig: { fresh in try await account.deviceConfig(fresh: fresh) },
            forgetSecret: { try secrets.delete() },
            unpair: unpair,
            defaults: defaults, build: build, usage: usage,
            hosted: build.hostedURL.map { worker in
                .live(worker: worker, account: account, authenticate: authenticate, secrets: secrets)
            }
        )
    }

    /// Onboarding's "Try with sample PRs".
    public func startSample() {
        usage.record(.onboardingPathChosen(.samples))
        sample = .sample(usage: usage, defaults: defaults)
    }

    /// Settings' "Connect your own Worker", or a setup link opened during the samples: back to onboarding, with no
    /// list setting of the samples' left behind.
    public func endSample() {
        usage.record(.samplesLeft)
        sample = nil
        PRSampleSet.resetListSettings(defaults)
    }

    /// The samples' way out, from their Settings. Where the build signs in with GitHub this is the sign-in itself, in
    /// one tap, with no stop at onboarding for a second "Sign in with GitHub". Signed in, the samples are over. A
    /// sign-in that he cancels or that fails leaves him in the samples, with what he did to them; their Settings say
    /// why it failed (`WorkerConnection.signInProblem`).
    public func leaveSample() async {
        guard connection.build.signInWithGitHub, connection.hosted != nil else {
            endSample()
            return
        }
        await signIn()
        if connection.isPaired {
            endSample()
        }
    }

    /// FeedbackKit's direct path when the Worker names its root (`feedback_direct`), with tokens from the Worker; else
    /// the Worker's `/feedback` routes, whose chats are kept on the device for offline.
    static func feedbackClient(prs: PRKitController, root: URL?, tokens: PRHubFeedbackTokens) -> FeatureClient {
        guard let root else {
            return FeatureClient(viewer: prs.client, keptIn: prs.keptFolder)
        }
        let direct = FeedbackDirect(baseURL: root, token: { renew in try await tokens.token(renew: renew) })
        return FeatureClient(direct: direct)
    }

    /// A new config that names another FeedbackKit root, or none: the Feedback tab moves to that path. Nothing when it
    /// is the same.
    public func followFeedbackPath() {
        guard let tokens = feedbackTokens else {
            return
        }
        let root = connection.config?.feedbackDirect?.url
        guard root != feedbackRoot else {
            return
        }
        feedbackRoot = root
        feedback = FeatureRequestsModel(client: Self.feedbackClient(prs: prs, root: root, tokens: tokens))
    }

    /// Settings' Disconnect: the Worker forgets this phone, the phone forgets the Worker and every PR it mirrored, so
    /// the next Worker starts from nothing.
    public func disconnect() async {
        await connection.disconnect()
        forgetLocalData()
    }

    /// Sign in with GitHub, from onboarding or Sign in again. Another account than the last one starts from nothing.
    public func signIn() async {
        guard let outcome = await connection.signIn() else {
            return
        }
        if outcome == .newPerson {
            prs.forgetEverything()
            await outbox?.forget()
        }
    }

    /// Settings' Sign out, or Sign in again's: the session ends, and the phone forgets every PR it mirrored.
    public func signOut() async {
        await connection.signOut()
        forgetLocalData()
    }

    /// Settings' Delete Account: the Worker deletes the account and revokes PRHub on GitHub; the phone forgets it all.
    public func deleteAccount() async throws(AccountActionError) {
        try await connection.deleteAccount()
        forgetLocalData()
    }

    /// The `signed_out` push.
    public func signedOutByGitHub() async {
        await connection.signedOutByGitHub()
    }

    private func forgetLocalData() {
        guard !connection.isPaired else {
            return
        }
        prs.forgetEverything()
        alertPermission.forgetDecline()
        if let outbox {
            Task { await outbox.forget() }
        }
    }

    /// A tapped review alert: its PR on the PRs tab, from the row it carried. Nothing while no Worker is paired, as
    /// during the samples.
    func openAlert(_ ref: PullRequestRef, row: PullRequestRow? = nil) {
        guard connection.isPaired, sample == nil else {
            return
        }
        navigation.showAlert(ref, row: row)
    }

    /// Just paired, or a config read: offers alerts once the Worker pushes.
    public func offerAlertsIfDue() async {
        guard !isSample, connection.isPaired, !connection.showsOnboarding else {
            return
        }
        await alertPermission.offerIfDue(
            workerPushes: connection.config?.isOn(.push) == true && AppIdentity.receivesPushes
        )
    }

    /// Launch, and every foreground: the Keychain again (a launch before the first unlock reads nothing), the
    /// config, then the list.
    public func becameActive() async {
        connection.reload()
        guard connection.isPaired, !connection.showsOnboarding else {
            return
        }
        await connection.refreshConfig()
        guard !connection.needsSignInAgain else {
            return
        }
        update.check(connection.config)
        sendPrefetchReports()
        // Beside the sync: every alert still in Notification Center opens its PR from the phone.
        async let alerts: Void = keepAlerts()
        // The sync sends this launch's push token too, when the Worker pushes.
        await prs.refresh(.foreground)
        await alerts
        await offerAlertsIfDue()
        #if os(iOS)
            metricKit?.update(isOn: connection.config?.metricKit == true)
            await metricKit?.flush()
        #endif
    }
}

extension PRHubEnvironment {
    /// MetricKit's reports waiting to be sent: Application Support, which iOS never clears.
    static var metricKitDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MetricKit", directoryHint: .isDirectory)
    }
}

extension PRHubEnvironment {
    /// How PRHubNotifications' prefetches went since the last time the app was in front, as `push_prefetch` events.
    /// The PRs of the alerts still in Notification Center, fetched if the Notification Service Extension missed them and
    /// kept while the alerts stay: at each foreground and each silent wake.
    public func keepAlerts() async {
        await prs.keepAlerts(PRHubNotificationDelegate.deliveredRows())
    }

    func sendPrefetchReports() {
        for entry in PRPushPrefetchLog(directory: PRHubPRHost.mirrorDirectory()).drain() {
            usage.record(.pushPrefetch(entry.outcome, milliseconds: entry.milliseconds))
        }
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
            removeAnthropicKey: { try await account.removeAnthropicKey() },
            setLinearKey: { try await account.setLinearKey($0) },
            removeLinearKey: { try await account.removeLinearKey() }
        )
    }
}

public extension PRHubEnvironment {
    /// The sample environment owns its own navigation and PR sessions; a PR link never ends the samples.
    @discardableResult
    func openPullRequestLink(_ url: URL) -> Bool {
        guard let destination = PRHubOpenLink(url) else {
            return false
        }
        let active = sample ?? self
        active.prs.open(destination.link)
        active.navigation.selectedTab = .prs
        return true
    }
}
