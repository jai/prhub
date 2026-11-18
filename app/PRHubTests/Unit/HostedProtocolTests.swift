import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

private let worker = URL(string: "https://prhub.example.workers.dev")!

/// Hosted sign-in protocol: PKCE, callback validation, and account requests through a scripted transport.
struct HostedSignInTests {
    @Test func theChallengeIsS256OfTheVerifier() {
        // RFC 7636, appendix B.
        #expect(SignInAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
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
        }, makeAttempt: { Self.attempt }, finish: { code, verifier in
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
        let signIn = HostedSignIn(worker: worker, authenticate: { _, _ in throw SignInError.cancelled },
                                  makeAttempt: { Self.attempt }, finish: { _, _ in
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
        #expect(expected.message?.firstMatch(of: /\d{3}/) == nil)
    }
}

/// The hosted Worker's account routes, as `AccountClient` sends them.
struct AccountClientTests {
    private static func client(_ stub: StubWorker) -> AccountClient {
        AccountClient(worker: { worker }, bearer: { "4242.session" }, exchange: { try await stub.exchange($0) })
    }

    private static func body(_ request: URLRequest) throws -> [String: String]? {
        try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
    }

    /// A config read failing at each foreground left no trace: each failed request now says its area and how.
    @Test func eachFailedRequestIsReportedWithItsAreaAndHow() async {
        let stub = StubWorker([.reply(status: 503, body: ""), .fail(.notConnectedToInternet), .fail(.timedOut)])
        let reports = Shared<[String]>([])
        var client = Self.client(stub)
        client.failed = { area, failure in reports.with { $0.append("\(area.rawValue) \(failure)") } }
        _ = try? await client.deviceConfig()
        _ = try? await client.removeAnthropicKey()
        _ = try? await client.signOut()
        #expect(reports.with { $0 } == ["config status(503)", "account offline", "account timeout"])
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
        (.reply(status: 200, body: "<html>"), .unreadable),
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
            #expect(expected.message.firstMatch(of: /\d{3}/) == nil)
        }
    }

    @Test func linearKeysGoOnlyInTheAuthenticatedBodyAndDisconnectUsesDelete() async throws {
        let stub = StubWorker([.reply(status: 200, body: #"{"linear_key":true}"#),
                               .reply(status: 200, body: #"{"linear_key":false}"#)])
        let client = Self.client(stub)
        try await client.setLinearKey("lin_api_synthetic01234567890")
        try await client.removeLinearKey()
        let requests = stub.requests.with { $0 }
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(requests.allSatisfy { $0.url?.path() == "/account/linear-key" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer 4242.session" })
        let body = try JSONDecoder().decode([String: String].self, from: #require(requests[0].httpBody))
        #expect(body == ["key": "lin_api_synthetic01234567890"])
        #expect(requests[1].httpBody == nil)
    }

    @Test func aLinearConnectionRequiresTheWorkersConfirmedAnswer() async {
        let stub = StubWorker([.reply(status: 200, body: "<html>Sign in</html>"),
                               .reply(status: 200, body: #"{"linear_key":true}"#)])
        await #expect(throws: AccountClient.Failure.decoding) {
            try await Self.client(stub).setLinearKey("lin_api_synthetic01234567890")
        }
        await #expect(throws: AccountClient.Failure.decoding) {
            try await Self.client(stub).removeLinearKey()
        }
    }

    @Test func aFreshConfigAsksTheWorkerToReadTheInstallationsFirst() async throws {
        let body = #"{"features":{},"hosted":true}"#
        let stub = StubWorker([.reply(status: 200, body: body), .reply(status: 200, body: body)])
        _ = try await Self.client(stub).deviceConfig()
        _ = try await Self.client(stub).deviceConfig(fresh: true)
        let urls = stub.requests.with { $0 }.map { $0.url?.absoluteString ?? "" }
        #expect(urls.map { $0.hasSuffix("/device/config") } == [true, false])
        #expect(urls[1].hasSuffix("/device/config?fresh=1"))
    }

    @Test func aConfigsRefusalKeepsItsCode() async {
        let stub = StubWorker([.reply(status: 401, body: #"{"error":{"code":"signed_out","message":"m"}}"#)])
        await #expect(throws: AccountClient.Failure.server("signed_out", 401)) {
            try await Self.client(stub).deviceConfig()
        }
    }
}
