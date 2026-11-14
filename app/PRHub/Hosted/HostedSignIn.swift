import CryptoKit
import Foundation

/// One Sign in with GitHub (docs/api.md, "Hosted sign-in"): a random `state` and a PKCE verifier (RFC 7636), kept in
/// memory only. The challenge goes to `/auth/github/start`; the verifier goes once, to `POST /auth/github/finish`.
struct SignInAttempt: Equatable, Sendable {
    let state: String
    let verifier: String

    /// 32 random bytes each, base64url: 43 characters of `A-Z a-z 0-9 - _`, inside both the state's and the
    /// verifier's alphabets and lengths.
    static func make() throws -> SignInAttempt {
        SignInAttempt(state: try DeviceSecretStore.generateSecret(), verifier: try DeviceSecretStore.generateSecret())
    }

    /// `BASE64URL(SHA256(verifier))`, the S256 challenge.
    var challenge: String {
        Self.challenge(for: verifier)
    }

    static func challenge(for verifier: String) -> String {
        DeviceSecretStore.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `GET /auth/github/start?state&code_challenge&code_challenge_method=S256` on the hosted Worker.
    func startURL(worker: URL) -> URL {
        worker.appending(path: "auth/github/start").appending(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
    }

    /// Where the Worker sends the session at the end: `https://<worker host>/auth/github/done`.
    static let callbackPath = "/auth/github/done"

    /// The one-time code from the callback, once its `state` is this attempt's. An `error` there is the Worker's or
    /// GitHub's refusal, in the contract's words.
    func code(from callback: URL) throws(SignInError) -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.path == Self.callbackPath else {
            throw .unreadable
        }
        let items = Dictionary(
            (parts.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        if let error = items["error"] {
            // `sign_in_expired` names no state: the Worker no longer knew it.
            if let state = items["state"], state != self.state {
                throw .stateMismatch
            }
            throw SignInError(callbackError: error)
        }
        guard items["state"] == state else {
            throw .stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            throw .unreadable
        }
        return code
    }
}

/// Why a sign-in stopped, in the words onboarding shows under its button.
enum SignInError: Error, Equatable, Sendable {
    /// The person closed the sheet: nothing to say.
    case cancelled
    /// `access_denied`: they cancelled on GitHub.
    case denied
    /// `sign_in_expired`, or `401 sign_in_invalid` from finish: too slow, or used already.
    case expired
    /// `github_refused` or another error GitHub sent.
    case githubRefused
    /// `github_unavailable`, or `503` from finish.
    case githubUnavailable
    /// The callback's `state` is not this attempt's: someone else's sign-in, never trusted.
    case stateMismatch
    /// `429 rate_limited`.
    case rateLimited
    case unreachable
    case server(status: Int)
    case unreadable
    /// The session secret could not be kept: a locked phone, mostly.
    case keychain
    /// The sign-in sheet could not open.
    case sessionUnavailable
    /// The Worker no longer knows this phone's session: signed out elsewhere, or the account was deleted.
    case sessionEnded

    init(callbackError: String) {
        switch callbackError {
        case "access_denied": self = .denied
        case "sign_in_expired": self = .expired
        case "github_unavailable": self = .githubUnavailable
        default: self = .githubRefused
        }
    }

    var message: String? {
        switch self {
        case .cancelled: nil
        case .denied: "You didn't authorize PRHub on GitHub. Sign in again when you're ready."
        case .expired: "That sign-in took too long or was already used. Sign in again."
        case .githubRefused: "GitHub didn't accept the sign-in. Sign in again."
        case .githubUnavailable: "GitHub couldn't be reached. Try again in a minute."
        case .stateMismatch:
            "That sign-in didn't start on this \(AppIdentity.deviceName), so PRHub ignored it. Sign in again."
        case .rateLimited: "Too many sign-ins from this network. Wait a minute and try again."
        case .unreachable: "Couldn't reach PRHub. Check your internet connection and try again."
        case .server: "PRHub had a problem on its side. Try again in a minute."
        case .unreadable: "PRHub's answer didn't make sense. Try again."
        case .keychain: AppIdentity.keychainProblem
        case .sessionUnavailable: "The sign-in page couldn't open. Try again."
        case .sessionEnded: "You were signed out of PRHub. Sign in again to see your PRs."
        }
    }
}

/// What `POST /auth/github/finish` answers.
struct SignInResult: Decodable, Equatable, Sendable {
    let secret: String
    let login: String
    let userId: String

    private enum CodingKeys: String, CodingKey {
        case secret, login
        case userId = "user_id"
    }
}

/// The browser half of a sign-in: open `start`, return the callback URL the session caught. The app's is
/// `ASWebAuthenticationSession` (`WebSignIn`); tests and the UI tests' fake Worker answer at once.
typealias Authenticate = @MainActor @Sendable (_ start: URL, _ callbackHost: String) async throws -> URL

/// A sign-in from end to end: a new attempt, the browser, the callback's checks, then `finish` with the verifier.
struct HostedSignIn: Sendable {
    var worker: URL
    var authenticate: Authenticate
    var finish: @Sendable (_ code: String, _ verifier: String) async throws -> SignInResult

    @MainActor
    func run() async throws(SignInError) -> SignInResult {
        guard let host = worker.host() else {
            throw .unreadable
        }
        let attempt: SignInAttempt
        do {
            attempt = try .make()
        } catch {
            throw .keychain
        }
        let callback: URL
        do {
            callback = try await authenticate(attempt.startURL(worker: worker), host)
        } catch let error as SignInError {
            throw error
        } catch {
            throw .sessionUnavailable
        }
        let code = try attempt.code(from: callback)
        do {
            return try await finish(code, attempt.verifier)
        } catch let error as AccountClient.Failure {
            throw SignInError(finish: error)
        } catch {
            throw .unreachable
        }
    }
}

extension SignInError {
    /// `POST /auth/github/finish`'s refusals.
    init(finish error: AccountClient.Failure) {
        switch error {
        case .server(_, 401), .server("sign_in_invalid", _): self = .expired
        case .server(_, 429): self = .rateLimited
        case .server(_, 503): self = .githubUnavailable
        case .server(_, let status): self = .server(status: status)
        case .transport, .notConnected: self = .unreachable
        case .decoding: self = .unreadable
        }
    }
}
