import Foundation
import Observation

/// PRHub's Worker: whether it has one, what that Worker serves, and the way in: pairing with a self-hosted pr-worker
/// (docs/api.md, "Pairing") or Sign in with GitHub on the hosted one ("Hosted sign-in"). Both end the same way: a Worker
/// URL and a bearer in the Keychain.
@MainActor
@Observable
final class WorkerConnection {
    enum Phase: Equatable {
        case idle
        case working(DevicePairing.Step)
        case invalidLink(SetupLink.Failure)
        case failed(PairingError)
        case signInFailed(SignInError)
        /// A setup link in a build without self-hosted Workers (`PRHubBuild.selfHosted`).
        case selfHostedOff
    }

    /// What a finished sign-in means for what the phone holds.
    enum SignInOutcome: Equatable {
        case samePerson
        /// Another GitHub account than the one before: nothing of the last one's may stay.
        case newPerson
    }

    /// The hosted Worker's routes, from the sign-in sheet to Delete Account. Errors are `SignInError` from `signIn`
    /// and `AccountClient.Failure` from the rest.
    struct Hosted: Sendable {
        var worker: URL
        var signIn: @MainActor @Sendable () async throws -> SignInResult
        /// Keeps the session secret where the device secret goes.
        var saveSecret: @Sendable (String) throws -> Void
        var signOut: @Sendable () async throws -> Void
        var deleteAccount: @Sendable () async throws -> Void
        var setAnthropicKey: @Sendable (String) async throws -> Void
        var removeAnthropicKey: @Sendable () async throws -> Void
    }

    /// The paired Worker's host; `nil` until a setup link has paired it.
    private(set) var host: String?
    /// The last `GET /device/config` read, kept across launches.
    private(set) var config: DeviceConfig?
    private(set) var phase: Phase = .idle
    /// A setup link opened while a Worker is paired already: its host, for the alert that says so.
    var ignoredLinkHost: String?
    /// The hosted Worker said this session is signed out: the `signed_out` push, a `401 signed_out`, or the config's
    /// `account.state`. The next config read sets it again.
    private(set) var isSignedOutOfGitHub = false
    /// Back from GitHub's install or installation pages: the hosted Worker is reading the installations again, so the
    /// list and Settings say Checking GitHub rather than what the last config said.
    private(set) var isCheckingInstallations = false
    let build: PRHubBuild

    @ObservationIgnored private let endpoint: WorkerEndpoint
    @ObservationIgnored private let pairing: DevicePairing
    /// `GET /device/config`; `true` asks the hosted Worker to read the installations first (`?fresh=1`).
    @ObservationIgnored private let fetchConfig: @Sendable (_ fresh: Bool) async throws -> DeviceConfig
    /// A GitHub install or installation page opened from the app; the next foreground reads the config fresh.
    @ObservationIgnored private var hasLeftForGitHub = false
    @ObservationIgnored private let forgetSecret: @Sendable () throws -> Void
    /// `DELETE /device/pair` with this phone's secret, before Disconnect forgets it. Failures are the Worker's to
    /// outlive: its record goes when another device pairs.
    @ObservationIgnored private let unpair: (@Sendable () async -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let usage: UsageAnalytics
    @ObservationIgnored let hosted: Hosted?

    static let configKey = "deviceConfig"

    init(
        endpoint: WorkerEndpoint, pairing: DevicePairing,
        fetchConfig: @escaping @Sendable (_ fresh: Bool) async throws -> DeviceConfig,
        forgetSecret: @escaping @Sendable () throws -> Void, unpair: (@Sendable () async -> Void)? = nil,
        defaults: UserDefaults = .standard, build: PRHubBuild = .current, usage: UsageAnalytics = .disabled(),
        hosted: Hosted? = nil
    ) {
        self.build = build
        self.usage = usage
        self.hosted = hosted
        self.endpoint = endpoint
        self.pairing = pairing
        self.fetchConfig = fetchConfig
        self.forgetSecret = forgetSecret
        self.unpair = unpair
        self.defaults = defaults
        host = endpoint.url?.host()
        config = defaults.data(forKey: Self.configKey).flatMap {
            try? JSONDecoder().decode(DeviceConfig.self, from: $0)
        }
        isSignedOutOfGitHub = config?.account?.state == .signedOut
    }

    /// Once a setup link has paired it.
    var isPaired: Bool {
        host != nil
    }

    var showsOnboarding: Bool {
        host == nil
    }

    /// Signed in with GitHub on the hosted Worker, as its config says or, before the first read, as its URL does.
    var isHosted: Bool {
        guard isPaired else {
            return false
        }
        if config?.hosted == true {
            return true
        }
        return hosted.map { endpoint.url == $0.worker } ?? false
    }

    /// The hosted Worker no longer acts for this person: the app shows Sign in again.
    var needsSignInAgain: Bool {
        isHosted && isSignedOutOfGitHub
    }

    /// Why the last sign-in stopped, in the words under its button. Nil when it did not, or he closed the sheet.
    var signInProblem: String? {
        if case let .signInFailed(error) = phase {
            return error.message
        }
        return nil
    }

    var isWorking: Bool {
        if case .working = phase {
            return true
        }
        return false
    }

    /// The Keychain may not have been readable at launch (a wake before the first unlock): read it again.
    func reload() {
        host = endpoint.url?.host()
    }

    /// A scanned, pasted or typed link.
    func connect(text: String) async {
        do {
            try await connect(SetupLink.parse(text))
        } catch {
            usage.record(.workerPairingFailed(.invalidLink))
            phase = .invalidLink(error)
        }
    }

    /// A Worker address and a code typed in apart.
    func connect(worker: String, code: String) async {
        do {
            try await connect(SetupLink(worker: worker, code: code))
        } catch {
            usage.record(.workerPairingFailed(.invalidLink))
            phase = .invalidLink(error)
        }
    }

    /// `prhub://setup?…`, opened from anywhere.
    func open(_ url: URL) {
        guard let link = try? SetupLink.parse(url.absoluteString) else {
            return
        }
        guard showsOnboarding else {
            ignoredLinkHost = host
            return
        }
        guard !isWorking else {
            return
        }
        guard build.selfHosted else {
            phase = .selfHostedOff
            return
        }
        Task { await connect(link) }
    }

    func connect(_ link: SetupLink) async {
        guard !isWorking else {
            return
        }
        guard build.selfHosted else {
            phase = .selfHostedOff
            return
        }
        usage.record(.onboardingPathChosen(.ownWorker))
        phase = .working(.pairing)
        do {
            try await pairing.run(link)
            // The first config is read before the tabs appear, so they appear as the Worker serves them.
            await readConfig()
            host = link.worker.host()
            phase = .idle
            usage.record(.workerPaired)
        } catch {
            usage.record(.workerPairingFailed(PairingFailureCode(error)))
            phase = .failed(error)
        }
    }

    /// `GET /device/config`, at launch, at every foreground and after pairing. A failed read keeps the last one. Back
    /// from GitHub's install pages, the hosted Worker reads the installations before it answers, and the app says it is
    /// checking until then.
    func refreshConfig() async {
        guard host != nil else {
            return
        }
        let isBackFromGitHub = hasLeftForGitHub && isHosted
        hasLeftForGitHub = false
        isCheckingInstallations = isBackFromGitHub
        await readConfig(fresh: isBackFromGitHub)
        isCheckingInstallations = false
    }

    /// A link about to open outside the app: one to the GitHub App's install or installation pages makes the next
    /// foreground's config fresh, as GitHub does not always send the browser back.
    func leavesForGitHub(_ url: URL) {
        if PRHubBuild.isInstallationPage(url) {
            hasLeftForGitHub = true
        }
    }

    private func readConfig(fresh isFresh: Bool = false) async {
        let fresh: DeviceConfig
        do {
            fresh = try await fetchConfig(isFresh)
        } catch AccountClient.Failure.server(let code, 401) where isHosted {
            sessionRefused(code: code)
            return
        } catch {
            return
        }
        config = fresh
        isSignedOutOfGitHub = fresh.account?.state == .signedOut
        defaults.set(try? JSONEncoder().encode(fresh), forKey: Self.configKey)
    }

    /// A `401` from the hosted Worker. `signed_out`: GitHub no longer honours the person's tokens, and Sign in again
    /// shows. Any other: the Worker no longer knows this session (signed out on this phone elsewhere, or the account
    /// deleted), so the phone forgets it and shows Sign in with GitHub.
    private func sessionRefused(code: String?) {
        if code == "signed_out" {
            isSignedOutOfGitHub = true
        } else if forget() {
            phase = .signInFailed(.sessionEnded)
        }
    }

    /// The `signed_out` push, or a `401` on any route: what the Worker says now decides.
    func checkSession() async {
        guard isHosted else {
            return
        }
        await readConfig()
    }

    /// The `signed_out` push: Sign in again at once, before the config confirms it.
    func signedOutByGitHub() async {
        guard isHosted else {
            return
        }
        isSignedOutOfGitHub = true
        await readConfig()
    }

    // MARK: - Hosted

    /// Sign in with GitHub: the sheet, `finish`, the session secret and the Worker URL kept, then the first config.
    /// From onboarding, or from Sign in again, whose old session is ended once the new one is kept.
    func signIn() async -> SignInOutcome? {
        guard let hosted, build.signInWithGitHub, !isWorking else {
            return nil
        }
        if !isPaired {
            usage.record(.onboardingPathChosen(.signInWithGitHub))
        }
        usage.record(.signInStarted(isPaired ? .signInAgain : .onboarding))
        phase = .working(.signingIn)
        let previousUser = isPaired ? config?.account?.userId : nil
        let result: SignInResult
        do {
            result = try await hosted.signIn()
        } catch {
            let error = error as? SignInError ?? .unreachable
            usage.record(.signInFailed(SignInFailureCode(error)))
            phase = error == .cancelled ? .idle : .signInFailed(error)
            return nil
        }
        if isPaired {
            try? await hosted.signOut()
        }
        do {
            try hosted.saveSecret(result.secret)
            try endpoint.save(hosted.worker)
        } catch {
            usage.record(.signInFailed(.keychain))
            phase = .signInFailed(.keychain)
            return nil
        }
        await readConfig()
        isSignedOutOfGitHub = config?.account?.state == .signedOut
        host = hosted.worker.host()
        phase = .idle
        usage.record(.signInSucceeded)
        return previousUser.map { $0 == result.userId ? .samePerson : .newPerson } ?? .samePerson
    }

    /// Settings' Sign out, and Sign in again's: the Worker ends this session where it can; the phone forgets it.
    func signOut() async {
        usage.record(.signedOut)
        try? await hosted?.signOut()
        forget()
    }

    /// Settings' Delete Account. A session the Worker no longer knows has nothing left to delete.
    func deleteAccount() async throws(AccountActionError) {
        guard let hosted else {
            return
        }
        do {
            try await hosted.deleteAccount()
        } catch {
            let error = AccountActionError(error as? AccountClient.Failure ?? .transport)
            guard error == .signedOut else {
                throw error
            }
        }
        usage.record(.accountDeleted)
        forget()
    }

    /// Settings' Anthropic key: kept on the Worker, never on the phone; the config then says which AI is on.
    func setAnthropicKey(_ key: String) async throws(AccountActionError) {
        try await accountAction(.anthropicKeySet) { try await $0.setAnthropicKey(key) }
    }

    func removeAnthropicKey() async throws(AccountActionError) {
        try await accountAction(.anthropicKeyRemoved) { try await $0.removeAnthropicKey() }
    }

    /// `done` is recorded once the Worker has taken the change.
    private func accountAction(
        _ done: AnalyticsEvent, _ action: (Hosted) async throws -> Void
    ) async throws(AccountActionError) {
        guard let hosted else {
            return
        }
        do {
            try await action(hosted)
        } catch {
            let error = AccountActionError(error as? AccountClient.Failure ?? .transport)
            await readConfig()
            throw error
        }
        usage.record(done)
        await readConfig()
    }

    /// The phone forgets the Worker, its config and the bearer. False when the Keychain could not be changed.
    @discardableResult private func forget() -> Bool {
        do {
            try endpoint.clear()
            try forgetSecret()
        } catch {
            phase = .failed(.keychain)
            return false
        }
        defaults.removeObject(forKey: Self.configKey)
        config = nil
        host = nil
        isSignedOutOfGitHub = false
        phase = .idle
        return true
    }

    /// Settings' Disconnect: tells the Worker to forget this phone's secret where it can, then forgets the Worker, its
    /// config and the secret here, so the next pairing is a new device.
    func disconnect() async {
        if host != nil {
            usage.record(.workerDisconnected)
            await unpair?()
        }
        forget()
    }
}
