import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

private let worker = URL(string: "https://prhub.example.workers.dev")!

/// `GET /device/config` on the hosted Worker, the session secret in the Keychain, and the build's flags.
struct HostedConfigTests {
    @Test func theSessionSecretIsKeptWhereTheDeviceSecretIs() throws {
        let store = DeviceSecretStore(
            service: "com.jaigovindani.prreview.tests", account: "session-\(UUID().uuidString)",
            isProtectedDataAvailable: { true }
        )
        defer { try? store.delete() }
        try store.save("4242.first")
        #expect(try store.load() == "4242.first")
        try store.save("4242.second")
        #expect(try store.loadOrCreate() == "4242.second")
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test func theBuildsFlagsComeFromInfoPlist() throws {
        let build = PRHubBuild(info: [
            "PRHubHostedHost": "prhub.example.workers.dev", "PRHubSignInWithGitHub": "YES",
            "PRHubSelfHosted": "NO", "PRHubSamples": "YES",
        ])
        #expect(build == PRHubBuild(hostedURL: worker, signInWithGitHub: true, selfHosted: false, samples: true))
        // No host, no sign-in; a missing flag is off.
        let bare = PRHubBuild(info: ["PRHubSignInWithGitHub": "YES"])
        #expect(!bare.signInWithGitHub && !bare.selfHosted && !bare.samples && bare.hostedURL == nil)
        let suite = "prhub-build-\(UUID().uuidString)"
        let overrides = try #require(UserDefaults(suiteName: suite))
        defer { overrides.removePersistentDomain(forName: suite) }
        overrides.set("YES", forKey: "PRHubSelfHosted")
        #expect(PRHubBuild(info: ["PRHubSelfHosted": "NO"], overrides: overrides).selfHosted)
    }
}

/// `WorkerConnection` on the hosted Worker: sign-in to the first config, signed out, a forgotten session, Sign out,
/// Delete Account, the key, and setup links in a build without self-hosting.
@MainActor
struct HostedConnectionTests {
    private static let build = PRHubBuild(hostedURL: worker, signInWithGitHub: true, selfHosted: false, samples: true)

    final class Fake: Sendable {
        let config = Shared(DeviceConfig(
            features: [.push], login: "octocat", hosted: true,
            account: .init(state: .signedIn, login: "octocat", userId: "4242")
        ))
        let configError = Shared<AccountClient.Failure?>(nil)
        let secret = Shared<String?>(nil)
        let calls = Shared<[String]>([])
        /// Each `GET /device/config`: whether it asked for `fresh=1`.
        let configReads = Shared<[Bool]>([])
        /// While true, a config read waits before it answers.
        let holdsConfig = Shared(false)
        let signInResult = Shared(SignInResult(secret: "4242.new", login: "octocat", userId: "4242"))
        let signInError = Shared<SignInError?>(nil)
        let actionError = Shared<AccountClient.Failure?>(nil)

        func record(_ call: String) {
            calls.with { $0.append(call) }
        }
    }

    private static func connection(
        _ fake: Fake, paired: Bool = false, usage: UsageAnalytics = .disabled()
    ) throws -> WorkerConnection {
        let endpoint = WorkerEndpoint(store: WorkerURLStore(
            service: "com.jaigovindani.prreview.tests", account: "hosted-url-\(UUID().uuidString)"
        ))
        try endpoint.clear()
        if paired {
            try endpoint.save(worker)
            fake.secret.with { $0 = "4242.old" }
        }
        let hosted = WorkerConnection.Hosted(
            worker: worker,
            signIn: {
                fake.record("signIn")
                if let error = fake.signInError.with({ $0 }) {
                    throw error
                }
                return fake.signInResult.with { $0 }
            },
            saveSecret: { secret in fake.secret.with { $0 = secret } },
            signOut: { fake.record("signOut \(fake.secret.with { $0 } ?? "-")") },
            deleteAccount: {
                fake.record("delete")
                if let error = fake.actionError.with({ $0 }) {
                    throw error
                }
            },
            setAnthropicKey: { key in
                fake.record("setKey \(key)")
                if let error = fake.actionError.with({ $0 }) {
                    throw error
                }
                fake.config.with { $0.account?.anthropicKey = true }
            },
            removeAnthropicKey: {
                fake.record("removeKey")
                fake.config.with { $0.account?.anthropicKey = false }
            }
        )
        return WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(pair: { _, _ in
                Issue.record("no pairing in this build")
                throw PairingClient.Failure.transport
            }, save: { _ in }),
            fetchConfig: { fresh in
                fake.configReads.with { $0.append(fresh) }
                while fake.holdsConfig.with({ $0 }) {
                    try await Task.sleep(for: .milliseconds(5))
                }
                if let error = fake.configError.with({ $0 }) {
                    throw error
                }
                return fake.config.with { $0 }
            },
            forgetSecret: { fake.secret.with { $0 = nil } },
            defaults: UserDefaults(suiteName: "prhub-hosted-\(UUID().uuidString)")!,
            build: build, usage: usage, hosted: hosted
        )
    }

    @Test func aSignInKeepsTheSessionAndReadsTheConfigBeforeTheListShows() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake)
        #expect(connection.showsOnboarding && !connection.isHosted)
        let outcome = await connection.signIn()
        #expect(outcome == .samePerson)
        #expect(fake.secret.with { $0 } == "4242.new")
        #expect(connection.host == "prhub.example.workers.dev")
        #expect(connection.isHosted && !connection.showsOnboarding && !connection.needsSignInAgain)
        #expect(connection.config?.account?.login == "octocat")
        #expect(connection.phase == .idle)
    }

    @Test func backFromGitHubsInstallPagesTheConfigIsReadFreshOnceWhileItSaysChecking() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        try connection.leavesForGitHub(#require(URL(string: "https://github.com/acme/api/pull/7")))
        await connection.refreshConfig()
        #expect(fake.configReads.with { $0 } == [false, false], "a PR link is not GitHub's install pages")

        connection.leavesForGitHub(PRHubBuild.appInstallURL)
        fake.holdsConfig.with { $0 = true }
        let reading = Task { await connection.refreshConfig() }
        while fake.configReads.with({ $0.count }) < 3 {
            await Task.yield()
        }
        #expect(connection.isCheckingInstallations, "Checking GitHub while the Worker reads")
        fake.holdsConfig.with { $0 = false }
        await reading.value
        #expect(fake.configReads.with { $0 } == [false, false, true])
        #expect(!connection.isCheckingInstallations)
        await connection.refreshConfig()
        #expect(fake.configReads.with { $0 }.last == false, "only the first foreground after GitHub")
    }

    @Test func aFailedOrCancelledSignInKeepsNothing() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake)
        fake.signInError.with { $0 = .denied }
        #expect(await connection.signIn() == nil)
        #expect(connection.phase == .signInFailed(.denied))
        fake.signInError.with { $0 = .cancelled }
        #expect(await connection.signIn() == nil)
        #expect(connection.phase == .idle)
        #expect(fake.secret.with { $0 } == nil && connection.showsOnboarding)
    }

    @Test func aSignInIsRecordedFromStartToEnd() async throws {
        let fake = Fake()
        let sink = AnalyticsTests.RecordingAnalytics()
        let connection = try Self.connection(fake, usage: AnalyticsTests.usage(sink))
        fake.signInError.with { $0 = .server(status: 502) }
        _ = await connection.signIn()
        fake.signInError.with { $0 = nil }
        _ = await connection.signIn()
        #expect(sink.events == [
            .onboardingPathChosen(.signInWithGitHub), .signInStarted(.onboarding), .signInFailed(.serverError),
            .onboardingPathChosen(.signInWithGitHub), .signInStarted(.onboarding), .signInSucceeded,
        ])
    }

    @Test func signInAgainIsNotAnOnboardingPath() async throws {
        let sink = AnalyticsTests.RecordingAnalytics()
        let connection = try Self.connection(Fake(), paired: true, usage: AnalyticsTests.usage(sink))
        _ = await connection.signIn()
        #expect(sink.events == [.signInStarted(.signInAgain), .signInSucceeded])
    }

    @Test func theKeyAndTheAccountAreRecordedOnceTheWorkerHasThem() async throws {
        let fake = Fake()
        let sink = AnalyticsTests.RecordingAnalytics()
        let connection = try Self.connection(fake, paired: true, usage: AnalyticsTests.usage(sink))
        try await connection.setAnthropicKey("key-0123456789abcdefghij")
        try await connection.removeAnthropicKey()
        fake.actionError.with { $0 = .server("anthropic_key_invalid", 422) }
        _ = try? await connection.setAnthropicKey("bad-key-012345678901")
        fake.actionError.with { $0 = nil }
        try await connection.deleteAccount()
        #expect(sink.events == [.anthropicKeySet, .anthropicKeyRemoved, .accountDeleted])
    }

    @Test func signedOutByGitHubShowsSignInAgainAndSigningInEndsTheOldSession() async throws {
        let fake = Fake()
        fake.config.with { $0.account = .init(state: .signedOut, login: "octocat", userId: "4242", reason: "revoked") }
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        #expect(connection.needsSignInAgain)
        fake.config.with { $0.account = .init(state: .signedIn, login: "octocat", userId: "4242") }
        #expect(await connection.signIn() == .samePerson)
        #expect(!connection.needsSignInAgain)
        #expect(fake.calls.with { $0 } == ["signIn", "signOut 4242.old"])
        #expect(fake.secret.with { $0 } == "4242.new")
    }

    @Test func anotherAccountIsANewPerson() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        fake.signInResult.with { $0 = SignInResult(secret: "77.new", login: "hubot", userId: "77") }
        #expect(await connection.signIn() == .newPerson)
    }

    @Test func theSignedOutPushShowsSignInAgainAtOnce() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        // The Worker cannot be asked: the push alone decides.
        fake.configError.with { $0 = .transport }
        await connection.signedOutByGitHub()
        #expect(connection.needsSignInAgain)
    }

    @Test func a401SignedOutShowsSignInAgain() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        fake.configError.with { $0 = .server("signed_out", 401) }
        await connection.checkSession()
        #expect(connection.needsSignInAgain && connection.isPaired)
    }

    @Test func aSessionTheWorkerForgotIsForgottenHere() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        fake.configError.with { $0 = .server("unauthorized", 401) }
        await connection.checkSession()
        #expect(connection.showsOnboarding && fake.secret.with { $0 } == nil)
        #expect(connection.phase == .signInFailed(.sessionEnded))
    }

    @Test func signOutEndsTheSessionAndForgetsIt() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        await connection.signOut()
        #expect(fake.calls.with { $0 } == ["signOut 4242.old"])
        #expect(connection.showsOnboarding && connection.config == nil && fake.secret.with { $0 } == nil)
    }

    @Test func deleteAccountForgetsEverythingOnceTheWorkerHasDeleted() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        fake.actionError.with { $0 = .transport }
        await #expect(throws: AccountActionError.unreachable) { try await connection.deleteAccount() }
        #expect(connection.isPaired, "a failed delete keeps the account")
        // Already gone on the Worker: nothing left to delete there.
        fake.actionError.with { $0 = .server("unauthorized", 401) }
        try await connection.deleteAccount()
        #expect(connection.showsOnboarding && fake.secret.with { $0 } == nil)
    }

    @Test func theKeyIsSetAndRemovedAndTheConfigSaysSo() async throws {
        let fake = Fake()
        let connection = try Self.connection(fake, paired: true)
        await connection.refreshConfig()
        try await connection.setAnthropicKey("key-0123456789abcdefghij")
        #expect(connection.config?.account?.anthropicKey == true)
        try await connection.removeAnthropicKey()
        #expect(connection.config?.account?.anthropicKey == false)
        fake.actionError.with { $0 = .server("anthropic_key_invalid", 422) }
        await #expect(throws: AccountActionError.keyRefused) { try await connection.setAnthropicKey("bad-key-012345678901") }
    }

    @Test func aSetupLinkInABuildWithoutSelfHostingSaysSo() async throws {
        let connection = try Self.connection(Fake())
        try connection.open(#require(URL(string: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA")))
        #expect(connection.phase == .selfHostedOff)
        await connection.connect(text: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA")
        #expect(connection.phase == .selfHostedOff && connection.showsOnboarding)
    }

    @Test func aPairedSelfHostedWorkerKeepsWorkingWithoutTheFlag() async throws {
        let endpoint = WorkerEndpoint(store: WorkerURLStore(
            service: "com.jaigovindani.prreview.tests", account: "self-hosted-url-\(UUID().uuidString)"
        ))
        try endpoint.save(#require(URL(string: "https://pr-review.alex.workers.dev")))
        let connection = try WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(pair: { _, _ in throw PairingClient.Failure.transport }, save: { _ in }),
            fetchConfig: { _ in DeviceConfig(features: [.push], login: "alex") }, forgetSecret: {},
            defaults: #require(UserDefaults(suiteName: "prhub-hosted-\(UUID().uuidString)")), build: Self.build
        )
        await connection.refreshConfig()
        #expect(connection.isPaired && !connection.showsOnboarding)
        #expect(!connection.isHosted && !connection.needsSignInAgain)
        #expect(connection.config?.login == "alex")
        try endpoint.clear()
    }

    @Test func theHostedListPointsAtTheAppsInstallPage() {
        let hosted = PRHubPRHost.configuration(DeviceConfig(features: [], hosted: true))
        #expect(hosted.emptyHint == PRHubPRHost.genericInstallHint)
        #expect(hosted.emptyHint?.link == PRHubBuild.appInstallURL)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [])).emptyHint == nil)
    }

    /// Signed in with no Anthropic key, the Key lines page says to add one, and opens Settings to do it.
    @Test func theHostedWorkerWithNoKeyPointsKeyLinesAtSettings() {
        let noKey = PRHubPRHost.configuration(DeviceConfig(features: [.push], hosted: true))
        #expect(!noKey.isOn(.keyLines))
        #expect(noKey.keyLinesHint == PRHubPRHost.anthropicKeyHint)
        #expect(noKey.keyLinesHint?.link == PRHubBuild.settingsURL)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [.keyLines], hosted: true)).keyLinesHint == nil)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [.push])).keyLinesHint == nil)
    }
}
