import Foundation

/// `POST /device/pair` (docs/api.md, "Pairing"), with this phone's device secret as the bearer, which the Worker need
/// not know yet. Sent once: a `401` means the code is spent or wrong, and the same request would only be refused again.
struct PairingClient: Sendable {
    enum Failure: Error, Equatable {
        /// The Worker's `error` code, when its body had one, and the status.
        case server(String?, Int)
        case transport
        case decoding
    }

    /// Which key the Worker wrote for this secret's fingerprint.
    struct PairResponse: Decodable, Equatable, Sendable {
        enum Role: String, Decodable, Sendable {
            /// This phone.
            case device
            /// An approved app (`npm run pair -- --app`), which a phone is not.
            case app
        }

        var role: Role
        var fingerprint: String
        var label: String?
    }

    /// `{"error": {"code", "message"}}`; the code alone is kept.
    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
        }

        let error: Detail?
    }

    var secret: @Sendable () throws -> String
    /// One request, once: `URLSession` in the app, a stand-in in tests.
    var exchange: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    func pair(worker: URL, code: String) async throws -> PairResponse {
        var request = URLRequest(url: worker.appending(path: "device/pair"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try secret())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw Failure.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.server((try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.code, http.statusCode)
        }
        do {
            return try JSONDecoder().decode(PairResponse.self, from: data)
        } catch {
            throw Failure.decoding
        }
    }
}
