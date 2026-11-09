import Foundation

/// The Worker's routes outside the PR screens (docs/api.md): `GET /device/config` with the error code a `401` carries,
/// and on the hosted Worker sign-in's finish, sign-out, Delete Account and the person's Anthropic key. Each request is
/// sent once; none is retried here.
struct AccountClient: Sendable {
    enum Failure: Error, Equatable, Sendable {
        /// The Worker's `error.code`, when its body had one, and the status.
        case server(String?, Int)
        case transport
        case decoding
        /// No Worker saved yet: nothing was sent.
        case notConnected
    }

    /// `{"error": {"code", "message"}}`; the code alone is kept.
    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
        }

        let error: Detail?
    }

    struct Deleted: Decodable, Equatable, Sendable {
        let deleted: Bool
        let githubRevoked: Bool

        private enum CodingKeys: String, CodingKey {
            case deleted
            case githubRevoked = "github_revoked"
        }
    }

    struct KeySet: Decodable, Equatable, Sendable {
        let anthropicKey: Bool
        let askAI: Bool

        private enum CodingKeys: String, CodingKey {
            case anthropicKey = "anthropic_key"
            case askAI = "ask_ai"
        }
    }

    /// Read per request, as the PR screens' are.
    var worker: @Sendable () -> URL?
    var bearer: @Sendable () throws -> String
    /// One request, once: `URLSession` in the app, a stand-in in tests.
    var exchange: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    func deviceConfig() async throws(Failure) -> DeviceConfig {
        try decode(DeviceConfig.self, try await send("GET", "device/config"))
    }

    /// `POST /auth/github/finish`, with no bearer: the code and the verifier are the proof.
    func finish(code: String, verifier: String) async throws(Failure) -> SignInResult {
        let body = try encode(["code": code, "code_verifier": verifier])
        return try decode(SignInResult.self, try await send("POST", "auth/github/finish", body: body, authorized: false))
    }

    /// `POST /auth/signout`: this phone's session ends. `204`.
    func signOut() async throws(Failure) {
        _ = try await send("POST", "auth/signout")
    }

    /// `DELETE /account` (App Review 5.1.1(v)).
    func deleteAccount() async throws(Failure) -> Deleted {
        try decode(Deleted.self, try await send("DELETE", "account"))
    }

    /// `PUT /account/anthropic-key`. The key goes in this body and nowhere else.
    func setAnthropicKey(_ key: String) async throws(Failure) -> KeySet {
        let body = try encode(["key": key])
        return try decode(KeySet.self, try await send("PUT", "account/anthropic-key", body: body))
    }

    /// `DELETE /account/anthropic-key`. `204`.
    func removeAnthropicKey() async throws(Failure) {
        _ = try await send("DELETE", "account/anthropic-key")
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, authorized: Bool = true)
        async throws(Failure) -> Data {
        guard let base = worker() else {
            throw .notConnected
        }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        if authorized {
            let secret: String
            do {
                secret = try bearer()
            } catch {
                throw .notConnected
            }
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw .transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw .transport
        }
        guard (200..<300).contains(http.statusCode) else {
            throw .server((try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.code, http.statusCode)
        }
        return data
    }

    private func encode(_ body: [String: String]) throws(Failure) -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw .decoding
        }
    }

    private func decode<Answer: Decodable>(_ type: Answer.Type, _ data: Data) throws(Failure) -> Answer {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .decoding
        }
    }
}

/// Why Settings' account action stopped: Sign out, Delete Account, or the Anthropic key.
enum AccountActionError: Error, Equatable, Sendable {
    /// `400 validation_error`: not the shape of an Anthropic key.
    case keyMalformed
    /// `422 anthropic_key_invalid`.
    case keyRefused
    /// `503 anthropic_unavailable`.
    case anthropicUnavailable
    /// `401`: the session is over; the app shows Sign in again.
    case signedOut
    case unreachable
    case server(status: Int)
    /// A 2xx whose body isn't the answer: a captive portal, or a Worker newer than this app.
    case unreadable

    init(_ failure: AccountClient.Failure) {
        switch failure {
        case .server("validation_error", 400): self = .keyMalformed
        case .server("anthropic_key_invalid", _): self = .keyRefused
        case .server("anthropic_unavailable", _): self = .anthropicUnavailable
        case .server(_, 401): self = .signedOut
        case .server(_, let status): self = .server(status: status)
        case .transport, .notConnected: self = .unreachable
        case .decoding: self = .unreadable
        }
    }

    var message: String {
        switch self {
        case .keyMalformed: "That isn't an Anthropic API key. Copy the whole key from console.anthropic.com."
        case .keyRefused: "Anthropic didn't accept that key. Check that it's active, then paste it again."
        case .anthropicUnavailable: "Anthropic couldn't be reached to check the key. Try again in a minute."
        case .signedOut: "You're signed out. Sign in with GitHub again."
        case .unreachable: "Couldn't reach PRHub. Check your internet connection and try again."
        case .server: "PRHub had a problem on its side. Try again in a minute."
        case .unreadable: "PRHub's answer didn't make sense. Update PRHub from the App Store and try again."
        }
    }
}
