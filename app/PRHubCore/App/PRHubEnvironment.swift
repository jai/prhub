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
        let storage = PRHubStorage.live(
            defaults: .standard, sampleConfiguration: UserDefaults(suiteName: "prhub-samples") ?? .standard
        )
        return PRHubEnvironment(
            endpoint: .live, secrets: .live(isProtectedDataAvailable: AppIdentity.protectedDataAvailability()),
            storage: storage, alertPermission: PRHubAlertPermission(center: .live, defaults: storage.prs.settings),
            build: .current, authenticate: WebSignIn.live, usage: usage, testFlightGroup: testFlightGroup,
            outbox: { PRHubOutbox(client: $0, file: PRHubOutbox.file, send: AppNetwork.oneTry) },
            metricReports: PRDiskFileStore(directory: metricKitDirectory)
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
    /// The path `feedback` is on: its FeedbackKit root, nil through the Worker, and the account whose list it keeps.
    @ObservationIgnored private var feedbackPath = PRHubFeedbackPath()
    @ObservationIgnored private var feedbackTokens: PRHubFeedbackTokens?
    /// Whether Feedback follows the Worker's config (`followFeedbackPath`): not over the samples, a fixture or a check.
    @ObservationIgnored private let followsFeedbackPath: Bool
    /// This phone, for the pushes of its feedback chats: registered with FeedbackKit while Feedback is on its direct
    /// path. The Mac gets no pushes, so no token arrives there.
    @ObservationIgnored public let feedbackDevices = PRHubFeedbackDevices()
    /// The last word to `feedbackDevices`, so a move to a path and a move off it reach it in order.
    @ObservationIgnored private var feedbackDevicesMove: Task<Void, Never>?
    /// Anonymous usage events, and Settings' switch for them.
    public let usage: UsageAnalytics
    @ObservationIgnored private let storage: PRHubStorage
    @ObservationIgnored private let network: PRNetwork?
    @ObservationIgnored var readDeliveredAlerts: @Sendable () async -> [PullRequestRow] = {
        await PRHubNotificationDelegate.deliveredRows()
    }

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
        openFeedback: { [weak self] chat in self?.openFeedbackChat(chat) },
        feedbackPush: { [weak self] push in
            guard let self else {
                return
            }
            Task { await self.badgedFeedback?.received(push) }
        },
        signedOut: { [weak self] in
            guard let self else {
                return
            }
            Task { await self.signedOutByGitHub() }
        }
    )

    init(
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, storage: PRHubStorage,
        alertPermission: PRHubAlertPermission, build: PRHubBuild, authenticate: @escaping Authenticate,
        usage: UsageAnalytics, testFlightGroup: TestFlightGroup,
        outbox makeOutbox: (PRViewerClient) -> PRHubOutbox, metricReports: any PRFileStore
    ) {
        let defaults = storage.prs.settings
        self.alertPermission = alertPermission
        alertPermission.usage = usage
        update = PRHubUpdate(group: testFlightGroup, defaults: defaults, usage: usage)
        self.usage = usage
        self.storage = storage
        network = nil
        let refusals = SessionRefusals()
        let host = PRHubPRHost(
            access: .paired(endpoint: endpoint, secret: { try secrets.loadOrCreate() }, refused: {
                await refusals.check()
            }),
            samples: nil, usage: usage
        )
        prs = PRKitController(host: host, storage: storage.prs)
        let outbox = makeOutbox(prs.client)
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
        followsFeedbackPath = true
        // The Worker's `/feedback` routes until `followFeedbackPath`, below, has read the config kept on the phone.
        feedback = FeatureRequestsModel(client: FeatureClient(viewer: prs.client, keptIn: prs.keptFolder), keep: nil)
        isSample = false
        let connection = connection
        host.config = { connection.config }
        host.isCheckingInstallations = { connection.isCheckingInstallations }
        host.leavesForGitHub = { connection.leavesForGitHub($0) }
        #if os(iOS)
            let reports = PRHubMetricReports(store: metricReports, defaults: defaults) { [client = prs.client] report in
                try await client.post("device/metrics", report)
            }
            metricKit = AppIdentity.isRunningTests ? nil : PRHubMetricKit(reports: reports)
            // The config as last read: MetricKit hands its payloads early in a launch, a wake's too.
            metricKit?.update(isOn: connection.config?.metricKit == true)
        #endif
        followFeedbackPath()
    }

    /// Over `access` (none: nothing is sent) and, for "Try with sample PRs", `samples`. `feedbackSamples` are a
    /// fixture's Feedback chats, which never leave the device.
    init(
        connection: WorkerConnection, storage: PRHubStorage, alertPermission: PRHubAlertPermission,
        access: PRViewerAccess = .offline, samples: PRSampleSet? = nil, isSample: Bool = false,
        usage: UsageAnalytics, outbox: (any PRKitOutbox)? = nil, update: PRHubUpdate? = nil,
        transport: (any HTTPTransport)? = nil, network: PRNetwork? = nil, feedbackSamples: FeatureSamples? = nil
    ) {
        let defaults = storage.prs.settings
        self.alertPermission = alertPermission
        alertPermission.usage = usage
        self.update = update ?? PRHubUpdate(
            defaults: defaults, usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults)
        )
        self.usage = usage
        self.storage = storage
        self.network = network
        let host = PRHubPRHost(access: access, samples: samples, usage: usage)
        host.outbox = outbox
        host.transportOverride = transport
        self.connection = connection
        prs = PRKitController(host: host, storage: storage.prs, network: network)
        self.outbox = nil
        self.isSample = isSample
        navigation = PRHubNavigation(pullRequests: prs)
        followsFeedbackPath = false
        feedback = FeatureRequestsModel(client: FeatureClient(viewer: prs.client, samples: feedbackSamples), keep: nil)
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
        endpoint: WorkerEndpoint, secrets: DeviceSecretStore, defaults: any PRKeyValueStore, build: PRHubBuild,
        authenticate: @escaping Authenticate, usage: UsageAnalytics,
        unpair: (@Sendable () async -> Void)? = nil
    ) -> WorkerConnection {
        let pairing = DevicePairing(
            pair: { worker, code in
                try await PairingClient(secret: { try secrets.loadOrCreate() }).pair(worker: worker, code: code)
            },
            save: { try endpoint.save($0) }
        )
        // Its failed requests are `request_failed`, each area's kind once a minute: a config read fails quietly.
        let reporter = PRFailureReporter { area, failure in
            Task { @MainActor in usage.record(.requestFailed(area, failure)) }
        }
        let account = AccountClient(
            worker: { endpoint.url }, bearer: { try secrets.loadOrCreate() }, failed: { reporter.failed($0, $1) }
        )
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
        sample = .sample(
            usage: usage, storage: storage.forSamples(), build: connection.build,
            alertPermission: PRHubAlertPermission(center: alertPermission.center, defaults: storage.prs.settings),
            network: network
        )
        sample?.readDeliveredAlerts = readDeliveredAlerts
    }

    /// Settings' "Connect your own Worker", or a setup link opened during the samples: back to onboarding, with no
    /// list setting of the samples' left behind.
    public func endSample() {
        usage.record(.samplesLeft)
        sample = nil
        PRSampleSet.resetListSettings(storage.prs.settings)
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

    /// Where the Worker's config says Feedback goes now, and whose list it keeps.
    public var feedbackPathWanted: PRHubFeedbackPath {
        PRHubFeedbackPath(host: connection.host, config: connection.isPaired ? connection.config : nil)
    }

    /// A config that names another FeedbackKit root, none, or another person: Feedback moves to that path, with that
    /// account's kept list and tokens of its own. Nothing when the path is the same.
    public func followFeedbackPath() {
        guard followsFeedbackPath else {
            return
        }
        let wanted = feedbackPathWanted
        guard wanted != feedbackPath || feedbackTokens == nil else {
            return
        }
        if feedbackPath.leavesItsAccount(for: wanted) {
            feedbackPath.keep?.clear()
        }
        feedbackPath = wanted
        makeFeedback()
    }

    /// FeedbackKit's direct path when the Worker names its root (`feedback_direct`), with tokens from the Worker; else
    /// the Worker's `/feedback` routes, whose chats are kept on the device for offline. The direct path's requests go
    /// through `PRHubFeedbackTransport`, so each send's outcome is recorded, and it registers this phone for the
    /// chats' pushes.
    private func makeFeedback() {
        let tokens = PRHubFeedbackTokens(client: prs.client)
        feedbackTokens = tokens
        let keep = AppIdentity.isRunningTests ? nil : feedbackPath.keep
        let devices = feedbackDevices
        guard let root = feedbackPath.root else {
            feedback = FeatureRequestsModel(
                client: FeatureClient(viewer: prs.client, keptIn: prs.keptFolder), keep: keep
            )
            feedbackDevicesMove = Task { [last = feedbackDevicesMove] in
                await last?.value
                await devices.disconnected()
            }
            return
        }
        let direct = Self.feedbackDirect(root: root, tokens: tokens, usage: usage)
        feedback = FeatureRequestsModel(client: FeatureClient(direct: direct), keep: keep)
        let environment: FeedbackPushEnvironment =
            APNSEnvironment.current() == APNSEnvironment.sandbox ? .sandbox : .production
        feedbackDevicesMove = Task { [last = feedbackDevicesMove] in
            await last?.value
            await devices.connected(
                register: { try await direct.registerDevice(token: $0, environment: environment) },
                unregister: { try await direct.unregisterDevice(token: $0) }
            )
        }
    }

    static func feedbackDirect(root: URL, tokens: PRHubFeedbackTokens, usage: UsageAnalytics) -> FeedbackDirect {
        let transport = PRHubFeedbackTransport { event in Task { @MainActor in usage.record(event) } }
        return FeedbackDirect(baseURL: root, token: { renew in try await tokens.token(renew: renew) }, http: transport)
    }

    /// Before the account leaves, while its session still answers: FeedbackKit forgets this phone, so the account's
    /// chats push nothing here. Best effort, for 3 seconds at most.
    private func forgetFeedbackDevice() async {
        let devices = feedbackDevices
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await devices.forget() }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The account left: its kept Feedback list goes, and Feedback starts again on whatever path is left.
    private func forgetFeedback() {
        guard followsFeedbackPath else {
            return
        }
        feedbackPath.keep?.clear()
        feedbackTokens = nil
        followFeedbackPath()
    }

    /// Settings' Disconnect: the Worker forgets this phone, the phone forgets the Worker and every PR it mirrored, so
    /// the next Worker starts from nothing.
    public func disconnect() async {
        await forgetFeedbackDevice()
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
        followFeedbackPath()
    }

    /// Settings' Sign out, or Sign in again's: the session ends, and the phone forgets every PR it mirrored.
    public func signOut() async {
        await forgetFeedbackDevice()
        await connection.signOut()
        forgetLocalData()
    }

    /// Settings' Delete Account: the Worker deletes the account and revokes PRHub on GitHub; the phone forgets it all.
    public func deleteAccount() async throws(AccountActionError) {
        await forgetFeedbackDevice()
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
        forgetFeedback()
        if let outbox {
            Task { await outbox.forget() }
        }
    }

    /// A tapped review alert: its PR on the PRs tab, from the row it carried. Nothing while no Worker is paired, as
    /// during the samples: `alert_ignored` says so, as the tap opened nothing.
    func openAlert(_ ref: PullRequestRef, row: PullRequestRow? = nil) {
        guard !isSample, connection.isPaired, sample == nil else {
            usage.record(.alertIgnored(isSample || sample != nil ? .samples : .notPaired))
            return
        }
        navigation.showAlert(ref, row: row)
    }

    /// A tapped push of a feedback chat (FeedbackKit's own, `FeedbackPush`): Feedback, on that chat. Nothing while no
    /// Worker is paired or it serves no Feedback, as there is no Feedback tab then.
    func openFeedbackChat(_ chat: String) {
        guard !isSample, connection.isPaired, sample == nil, connection.config?.isOn(.feedback) == true else {
            return
        }
        navigation.showFeedbackChat(chat)
    }

    /// The Feedback whose chats badge its tab and the Mac's toolbar button: none while no Worker is paired or it serves
    /// no Feedback, as there is no Feedback then.
    public var badgedFeedback: FeatureRequestsModel? {
        !isSample && connection.isPaired && sample == nil && connection.config?.isOn(.feedback) == true ? feedback : nil
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
        followFeedbackPath()
        // A registration with FeedbackKit that failed goes again.
        Task { await feedbackDevices.retry() }
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
        await prs.keepAlerts(readDeliveredAlerts())
    }

    func sendPrefetchReports() {
        for entry in PRPushPrefetchLog(store: storage.prs.mirror).drain() {
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
    /// The sample environment owns its own navigation and PR sessions; a PR link never ends the samples. A
    /// `prhub-pr://open` handoff, as the share sheet sends, is `pr_link_opened`: opened, or not a PR PRHub opens.
    @discardableResult
    func openPullRequestLink(_ url: URL) -> Bool {
        guard let destination = PRHubOpenLink(url) else {
            if url.scheme?.lowercased() == PRHubOpenLink.scheme {
                usage.record(.pullRequestLinkOpened(.notAPullRequest))
            }
            return false
        }
        usage.record(.pullRequestLinkOpened(.opened))
        let active = sample ?? self
        active.prs.open(destination.link)
        active.navigation.selectedTab = .prs
        return true
    }
}
