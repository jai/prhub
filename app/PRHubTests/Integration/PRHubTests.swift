import Foundation
import PRContractFixtures
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing

/// The pr-worker's `GET /device/config` fixture decodes (docs/api.md), and a pairing outlives a relaunch: the Worker in
/// the Keychain, its config in the preferences. Pairing's logic is the unit layer's `WorkerConnectionPairingTests`.
@MainActor
struct PRHubTests {
    private let resources = IntegrationResources()

    // MARK: - `GET /device/config`

    @Test func theWorkersFixtureDecodes() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: ContractFixtures.data("device-config.json"))
        #expect(config.features == [.keyLines, .rewrite, .push])
        #expect(config.login == "alex" && config.orgs == ["acme"])
        #expect(config.appLatest?.build(for: .internal) == AppBuild(version: "1.0", build: "212"))
        #expect(config.appLatest?.build(for: .public) == AppBuild(version: "1.0", build: "198"))
    }

    // MARK: - Pairing

    private func makeConnection(
        endpoint: WorkerEndpoint, config: DeviceConfig, unpaired: Shared<Int>, forgotten: Shared<Int>,
        defaults: UserDefaults? = nil
    ) -> WorkerConnection {
        WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(
                pair: { _, code in
                    #expect(code == "7KQ2M9XA")
                    return .init(role: .device, fingerprint: String(repeating: "1", count: 64), label: nil)
                },
                save: { try endpoint.save($0) }
            ),
            fetchConfig: { _ in config }, forgetSecret: { forgotten.with { $0 += 1 } },
            unpair: { unpaired.with { $0 += 1 } },
            defaults: defaults ?? resources.defaults(),
            build: PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: true, samples: true),
            usage: resources.usage()
        )
    }

    @Test func aPRWorkerAdmitsThePhoneAtOnceAndItsConfigIsReadBeforeThePRsShow() async throws {
        let keychain = resources.keychain()
        let endpoint = WorkerEndpoint(store: keychain)
        let defaults = resources.defaults()
        let config = DeviceConfig(features: [.askAI, .push], login: "alex", orgs: ["acme"])
        let connection = makeConnection(
            endpoint: endpoint, config: config, unpaired: Shared(0), forgotten: Shared(0), defaults: defaults
        )
        #expect(connection.showsOnboarding)

        await connection.connect(text: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7kq2-m9xa")
        #expect(!connection.showsOnboarding)
        #expect(connection.phase == .idle)
        #expect(connection.host == "pr-review.alex.workers.dev")
        #expect(endpoint.url?.absoluteString == "https://pr-review.alex.workers.dev")
        #expect(connection.config == config)

        // A later launch finds both: the Worker in the Keychain, the config in the cache.
        let relaunched = makeConnection(
            endpoint: WorkerEndpoint(store: keychain), config: config, unpaired: Shared(0), forgotten: Shared(0),
            defaults: defaults
        )
        #expect(relaunched.isPaired && relaunched.config == config)
        try endpoint.clear()
    }
}
