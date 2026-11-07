import Foundation
import Testing
@testable import PRHub

private let worker = URL(string: "https://prhub.example.workers.dev")!

/// Sign in with GitHub and the hosted account (docs/api.md, "Hosted sign-in"): PKCE and state, the callback, the
/// session in the Keychain, signed-out handling, Delete Account and the Anthropic key, and the build's ways in.
struct HostedSignInTests {
    @Test func theChallengeIsS256OfTheVerifier() {
        // RFC 7636, appendix B.
        #expect(SignInAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func eachAttemptHasItsOwnStateAndVerifierInTheContractsAlphabet() throws {
        let first = try SignInAttempt.make()
        let second = try SignInAttempt.make()
        #expect(first.state != second.state && first.verifier != second.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-")
        for value in [first.state, first.verifier] {
            #expect((43...128).contains(value.count))
            #expect(value.unicodeScalars.allSatisfy(allowed.contains))
        }
    }

    @Test func startCarriesTheStateAndTheChallengeNeverTheVerifier() throws {
        let attempt = SignInAttempt(state: "state-1234567890ab", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = attempt.startURL(worker: worker)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "prhub.example.workers.dev" && parts.path == "/auth/github/start")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "state": "state-1234567890ab",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
        ])
        #expect(!url.absoluteString.contains(attempt.verifier))
    }

    private static let attempt = SignInAttempt(state: "app-state-0123456789", verifier: "v")

    private static func callback(_ query: String, path: String = "/auth/github/done") -> URL {
        URL(string: "https://prhub.example.workers.dev\(path)?\(query)")!
    }

    @Test func theCallbacksCodeIsTakenOnlyWithThisAttemptsState() throws {
        #expect(try Self.attempt.code(from: Self.callback("code=abc&state=app-state-0123456789")) == "abc")
        #expect(throws: SignInError.stateMismatch) {
            try Self.attempt.code(from: Self.callback("code=abc&state=someone-elses-state"))
        }
        #expect(throws: SignInError.stateMismatch) { try Self.attempt.code(from: Self.callback("code=abc")) }
        #expect(throws: SignInError.unreadable) {
            try Self.attempt.code(from: Self.callback("code=abc&state=app-state-0123456789", path: "/auth/github/x"))
        }
        #expect(throws: SignInError.unreadable) {
            try Self.attempt.code(from: Self.callback("state=app-state-0123456789"))
        }
    }

    @Test(arguments: [
        ("error=access_denied&state=app-state-0123456789", SignInError.denied),
        ("error=sign_in_expired", .expired),
        ("error=github_refused&state=app-state-0123456789", .githubRefused),
        ("error=github_unavailable&state=app-state-0123456789", .githubUnavailable),
        ("error=something_new&state=app-state-0123456789", .githubRefused),
        ("error=access_denied&state=someone-elses-state", .stateMismatch),
    ])
    func theCallbacksErrorsBecomeWords(_ query: String, _ expected: SignInError) {
        #expect(throws: expected) { try Self.attempt.code(from: Self.callback(query)) }
        #expect(expected.message?.isEmpty == false)
    }

    @MainActor @Test func aSignInSendsTheVerifierBehindTheChallengeToFinish() async throws {
        let challenge = Shared<String?>(nil)
        let sent = Shared<(String, String)?>(nil)
        let signIn = HostedSignIn(worker: worker, authenticate: { start, host in
            #expect(host == "prhub.example.workers.dev")
            let items = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? []
            challenge.with { $0 = items.first { $0.name == "code_challenge" }?.value }
            let state = items.first { $0.name == "state" }?.value ?? ""
            return URL(string: "https://\(host)/auth/github/done?code=one-time&state=\(state)")!
        }, finish: { code, verifier in
            sent.with { $0 = (code, verifier) }
            return SignInResult(secret: "4242.secret", login: "octocat", userId: "4242")
        })
        let result = try await signIn.run()
        #expect(result == SignInResult(secret: "4242.secret", login: "octocat", userId: "4242"))
        let (code, verifier) = try #require(sent.with { $0 })
        #expect(code == "one-time")
        #expect(SignInAttempt.challenge(for: verifier) == challenge.with { $0 })
    }

    @MainActor @Test func aClosedSheetIsCancelledAndFinishIsNeverAsked() async {
        let signIn = HostedSignIn(worker: worker, authenticate: { _, _ in throw SignInError.cancelled }, finish: { _, _ in
            Issue.record("nothing to finish")
            throw AccountClient.Failure.transport
        })
        await #expect(throws: SignInError.cancelled) { try await signIn.run() }
        #expect(SignInError.cancelled.message == nil)
    }

    @Test(arguments: [
        (AccountClient.Failure.server("sign_in_invalid", 401), SignInError.expired),
        (.server("rate_limited", 429), .rateLimited),
        (.server("github_unavailable", 503), .githubUnavailable),
        (.server(nil, 500), .server(status: 500)),
        (.transport, .unreachable),
        (.decoding, .unreadable),
    ])
    func finishsRefusalsBecomeWords(_ failure: AccountClient.Failure, _ expected: SignInError) {
        #expect(SignInError(finish: failure) == expected)
    }
}

/// The hosted Worker's account routes, as `AccountClient` sends them.
struct AccountClientTests {
    private static func client(_ stub: StubWorker) -> AccountClient {
        AccountClient(worker: { worker }, bearer: { "4242.session" }, exchange: { try await stub.exchange($0) })
    }

    private static func body(_ request: URLRequest) throws -> [String: String]? {
        try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
    }

    @Test func finishSendsTheCodeAndVerifierWithNoBearer() async throws {
        let stub = StubWorker([.reply(status: 200, body: #"{"secret":"4242.abc","login":"octocat","user_id":"4242"}"#)])
        let result = try await Self.client(stub).finish(code: "one-time", verifier: "the-verifier")
        #expect(result == SignInResult(secret: "4242.abc", login: "octocat", userId: "4242"))
        let request = try #require(stub.requests.with { $0.first })
        #expect(request.httpMethod == "POST" && request.url?.path() == "/auth/github/finish")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try Self.body(request) == ["code": "one-time", "code_verifier": "the-verifier"])
    }

    @Test func theKeyIsPutWithTheSessionAndRemovedWithADelete() async throws {
        let stub = StubWorker([
            .reply(status: 200, body: #"{"anthropic_key":true,"ask_ai":false}"#),
            .reply(status: 204, body: ""),
        ])
        let client = Self.client(stub)
        let answer = try await client.setAnthropicKey("key-0123456789abcdefghij")
        #expect(answer == AccountClient.KeySet(anthropicKey: true, askAI: false))
        try await client.removeAnthropicKey()
        let requests = stub.requests.with { $0 }
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(requests.allSatisfy { $0.url?.path() == "/account/anthropic-key" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer 4242.session" })
        #expect(try Self.body(requests[0]) == ["key": "key-0123456789abcdefghij"])
    }

    @Test func signOutAndDeleteAccountUseTheirRoutes() async throws {
        let stub = StubWorker([
            .reply(status: 204, body: ""),
            .reply(status: 200, body: #"{"deleted":true,"github_revoked":false}"#),
        ])
        let client = Self.client(stub)
        try await client.signOut()
        #expect(try await client.deleteAccount() == AccountClient.Deleted(deleted: true, githubRevoked: false))
        let requests = stub.requests.with { $0 }
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
            == ["POST /auth/signout", "DELETE /account"])
    }

    @Test(arguments: [
        (StubWorker.Answer.reply(status: 400, body: #"{"error":{"code":"validation_error","message":"m"}}"#),
         AccountActionError.keyMalformed),
        (.reply(status: 422, body: #"{"error":{"code":"anthropic_key_invalid","message":"m"}}"#), .keyRefused),
        (.reply(status: 503, body: #"{"error":{"code":"anthropic_unavailable","message":"m"}}"#), .anthropicUnavailable),
        (.reply(status: 401, body: #"{"error":{"code":"signed_out","message":"m"}}"#), .signedOut),
        (.reply(status: 500, body: "oops"), .server(status: 500)),
        (.fail(.notConnectedToInternet), .unreachable),
    ])
    func aRefusedKeySaysWhy(_ answer: StubWorker.Answer, _ expected: AccountActionError) async {
        let client = Self.client(StubWorker([answer]))
        do {
            _ = try await client.setAnthropicKey("key-0123456789abcdefghij")
            Issue.record("refused")
        } catch {
            #expect(AccountActionError(error) == expected)
            #expect(!expected.message.isEmpty)
        }
    }

    @Test func aConfigsRefusalKeepsItsCode() async {
        let stub = StubWorker([.reply(status: 401, body: #"{"error":{"code":"signed_out","message":"m"}}"#)])
        await #expect(throws: AccountClient.Failure.server("signed_out", 401)) {
            try await Self.client(stub).deviceConfig()
        }
    }
}

/// `GET /device/config` on the hosted Worker, the session secret in the Keychain, and the build's flags.
struct HostedConfigTests {
    @Test func readsTheHostedWorkersAccount() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data("""
        {"features":{"key_lines":true,"rewrite":true,"push":true},"login":"octocat","hosted":true,
         "account":{"state":"signed_in","login":"octocat","user_id":"4242","anthropic_key":true}}
        """.utf8))
        #expect(config.hosted)
        #expect(config.account == DeviceConfig.Account(
            state: .signedIn, login: "octocat", userId: "4242", anthropicKey: true
        ))
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func aSignedOutOrUnknownStateReadsAsSignedOut() throws {
        let signedOut = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"""
        {"features":{},"hosted":true,"account":{"state":"signed_out","reason":"revoked","anthropic_key":false}}
        """#.utf8))
        #expect(signedOut.account?.state == .signedOut && signedOut.account?.reason == "revoked")
        let unknown = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"""
        {"features":{},"hosted":true,"account":{"state":"paused"}}
        """#.utf8))
        #expect(unknown.account?.state == .signedOut)
    }

    @Test func aSelfHostedConfigIsNotHosted() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"{"features":{"push":true}}"#.utf8))
        #expect(!config.hosted && config.account == nil)
    }

    @Test func theSessionSecretIsKeptWhereTheDeviceSecretIs() throws {
        let store = DeviceSecretStore(
            service: "com.jaigovindani.prreview.tests", account: "session-\(UUID().uuidString)",
            isProtectedDataAvailable: { true }
        )
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
        overrides.set("YES", forKey: "PRHubSelfHosted")
        #expect(PRHubBuild(info: ["PRHubSelfHosted": "NO"], overrides: overrides).selfHosted)
        overrides.removePersistentDomain(forName: suite)
    }

    @Test func theAppsBuildSignsInAndHidesSelfHosting() {
        // app/Config/PRHub.xcconfig's defaults.
        let build = PRHubBuild(info: Bundle.main.infoDictionary ?? [:])
        #expect(build.signInWithGitHub && build.samples && !build.selfHosted)
        #expect(build.hostedURL?.scheme == "https")
    }

    @Test func theSignedOutPushIsKnown() {
        #expect(PRHubNotificationDelegate.isSignedOut(["reason": "signed_out"]))
        #expect(!PRHubNotificationDelegate.isSignedOut(["reason": "pr_sync"]))
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
        let signInResult = Shared(SignInResult(secret: "4242.new", login: "octocat", userId: "4242"))
        let signInError = Shared<SignInError?>(nil)
        let actionError = Shared<AccountClient.Failure?>(nil)

        func record(_ call: String) {
            calls.with { $0.append(call) }
        }
    }

    private static func connection(_ fake: Fake, paired: Bool = false) throws -> WorkerConnection {
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
            fetchConfig: {
                if let error = fake.configError.with({ $0 }) {
                    throw error
                }
                return fake.config.with { $0 }
            },
            forgetSecret: { fake.secret.with { $0 = nil } },
            defaults: UserDefaults(suiteName: "prhub-hosted-\(UUID().uuidString)")!,
            build: build, hosted: hosted
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
        connection.open(URL(string: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA")!)
        #expect(connection.phase == .selfHostedOff)
        await connection.connect(text: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA")
        #expect(connection.phase == .selfHostedOff && connection.showsOnboarding)
    }

    @Test func aPairedSelfHostedWorkerKeepsWorkingWithoutTheFlag() async throws {
        let endpoint = WorkerEndpoint(store: WorkerURLStore(
            service: "com.jaigovindani.prreview.tests", account: "self-hosted-url-\(UUID().uuidString)"
        ))
        try endpoint.save(URL(string: "https://pr-review.alex.workers.dev")!)
        let connection = WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(pair: { _, _ in throw PairingClient.Failure.transport }, save: { _ in }),
            fetchConfig: { DeviceConfig(features: [.push], login: "alex") }, forgetSecret: {},
            defaults: UserDefaults(suiteName: "prhub-hosted-\(UUID().uuidString)")!, build: Self.build
        )
        await connection.refreshConfig()
        #expect(connection.isPaired && !connection.showsOnboarding)
        #expect(!connection.isHosted && !connection.needsSignInAgain)
        #expect(connection.config?.login == "alex")
        try endpoint.clear()
    }

    @Test func theHostedListPointsAtTheAppsInstallPage() {
        let hosted = PRHubPRHost.configuration(DeviceConfig(features: [], hosted: true))
        #expect(hosted.emptyHint?.link == PRHubBuild.appInstallURL)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [])).emptyHint == nil)
    }
}
