import Foundation
import Testing
@testable import PRHub

/// `POST /device/pair` (docs/api.md, "Pairing"): the request, and every answer the contract names as the words the
/// onboarding screen shows.
struct PairingTests {
    private static let worker = URL(string: "https://pr-review.alex.workers.dev")!
    // swiftlint:disable:next force_try
    private static let link = try! SetupLink(worker: "pr-review.alex.workers.dev", code: "7KQ2M9XA")
    private static let secret = "s3cret-device-secret-0123456789"

    private static func client(_ worker: StubWorker) -> PairingClient {
        PairingClient(secret: { secret }, exchange: { try await worker.exchange($0) })
    }

    @Test func pairPostsTheCodeWithTheDeviceSecretAsBearer() async throws {
        let fingerprint = String(repeating: "a", count: 64)
        let worker = StubWorker([
            .reply(status: 200, body: #"{"role":"device","fingerprint":"\#(fingerprint)","label":null}"#),
        ])
        let response = try await Self.client(worker).pair(worker: Self.worker, code: "7KQ2M9XA")
        #expect(response.role == .device)
        #expect(response.label == nil)
        let request = try #require(worker.requests.with { $0.first })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pr-review.alex.workers.dev/device/pair")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["code": "7KQ2M9XA"])
    }

    private static func envelope(_ code: String) -> String {
        #"{"error":{"code":"\#(code)","message":"words for the log"}}"#
    }

    @Test(arguments: [
        (StubWorker.Answer.reply(status: 400, body: envelope("validation_error")), PairingError.codeMalformed),
        (.reply(status: 401, body: envelope("pairing_code_invalid")), .codeRefused),
        (.reply(status: 401, body: envelope("unauthorized")), .secretRefused),
        (.reply(status: 404, body: envelope("not_found")), .pairingUnsupported),
        (.reply(status: 404, body: "Not Found"), .pairingUnsupported),
        (.reply(status: 500, body: envelope("internal_error")), .server(status: 500)),
        (.reply(status: 200, body: "<html>"), .unreadable),
        (.fail(.cannotFindHost), .unreachable(host: "pr-review.alex.workers.dev")),
    ])
    func eachAnswerBecomesItsOwnWords(_ answer: StubWorker.Answer, _ expected: PairingError) async {
        let worker = StubWorker([answer])
        let client = Self.client(worker)
        let pairing = DevicePairing(
            pair: { url, code in try await client.pair(worker: url, code: code) },
            save: { _ in Issue.record("a refused pairing saves nothing") }
        )
        await #expect(throws: expected) { try await pairing.run(Self.link) }
        // Sent once: a code is single use, so a refusal is never asked again.
        #expect(worker.requests.with { $0.count } == 1)
        #expect(!expected.message.isEmpty)
        #expect(!expected.message.contains("words for the log"))
    }

    @Test func aCodeForAnAppIsNotAPhonesCode() async {
        let pairing = DevicePairing(
            pair: { _, _ in .init(role: .app, fingerprint: String(repeating: "b", count: 64), label: "Alex's Mac") },
            save: { _ in Issue.record("an app's code saves nothing") }
        )
        await #expect(throws: PairingError.appCode) { try await pairing.run(Self.link) }
        #expect(PairingError.appCode.needsNewCode)
    }

    @Test func aWorkerThatCannotBeSavedIsAKeychainFailure() async {
        let pairing = DevicePairing(
            pair: { _, _ in .init(role: .device, fingerprint: String(repeating: "c", count: 64), label: nil) },
            save: { _ in throw DeviceSecretStore.Failure.protectedDataUnavailable }
        )
        await #expect(throws: PairingError.keychain) { try await pairing.run(Self.link) }
    }
}
