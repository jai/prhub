import Foundation
import Testing
@testable import PRHub
@testable import PRKit

private let prHubSecret = "prhub-device-secret-0123456789"

/// PRHub's requests go to the paired pr-worker with the device secret as the bearer, the PR screens follow its
/// `GET /device/config` (docs/api.md), and pairing needs nothing after `POST /device/pair`.
@MainActor
struct PRHubTests {
    private static func endpoint(saving url: String? = nil) throws -> WorkerEndpoint {
        let endpoint = WorkerEndpoint(store: WorkerURLStore(
            service: "com.jaigovindani.prreview.tests", account: "prhub-url-\(UUID().uuidString)"
        ))
        try endpoint.clear()
        if let url {
            try endpoint.save(URL(string: url)!)
        }
        return endpoint
    }

    private static func decode(_ json: String) throws -> DeviceConfig {
        try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
    }

    private static func model(_ config: DeviceConfig?) -> PRsModel {
        let model = PRsModel(client: PRViewerClient(access: .paired(
            endpoint: WorkerEndpoint(fixed: URL(string: "https://pr-review.alex.workers.dev")!), secret: { prHubSecret }
        )))
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    // MARK: - Where requests go

    @Test func aPairedRequestGoesToThePairedWorkerWithTheDeviceSecret() async throws {
        let endpoint = try Self.endpoint(saving: "https://pr-review.alex.workers.dev")
        let client = PRViewerClient(access: .paired(endpoint: endpoint, secret: { prHubSecret }))
        let request = try await client.outboxRequest(path: "prs/acme/api/7/write", body: Data("{}".utf8))
        #expect(request.url?.host() == "pr-review.alex.workers.dev")
        #expect(request.url?.path() == "/prs/acme/api/7/write")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(prHubSecret)")
        try endpoint.clear()
    }

    @Test func beforePairingNothingIsBuilt() async throws {
        let endpoint = try Self.endpoint()
        let client = PRViewerClient(access: .paired(endpoint: endpoint, secret: { prHubSecret }))
        await #expect(throws: PRWorkerError.notPaired) {
            try await client.outboxRequest(path: "prs", body: Data())
        }
    }

    // MARK: - `GET /device/config`

    @Test func readsAPRWorkersConfig() throws {
        let config = try Self.decode("""
        {"features":{"ask_ai":true,"key_lines":true,"rewrite":false,"feedback":false,"push":true,"webhooks":false,
        "teleport":true},"login":"alex","orgs":["acme"]}
        """)
        #expect(config.features == [.askAI, .keyLines, .push])
        #expect(config.login == "alex")
        #expect(config.orgs == ["acme"])
        // Kept across launches: the cache reads back the same.
        let saved = try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config))
        #expect(saved == config)
    }

    @Test func theWorkersFixtureDecodes() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Fixture.data("device-config.json"))
        #expect(config.features == [.keyLines, .rewrite, .push])
        #expect(config.login == "alex" && config.orgs == ["acme"])
        #expect(config.appLatest?.build(for: .internal) == AppBuild(version: "1.0", build: "212"))
        #expect(config.appLatest?.build(for: .public) == AppBuild(version: "1.0", build: "198"))
    }

    @Test func aWorkerThatCouldNotAskGitHubHasNoLoginAndNoOrgs() throws {
        let config = try Self.decode(#"{"features":{"push":"yes"},"login":null}"#)
        #expect(config.features.isEmpty)
        #expect(config.login == nil && config.orgs == nil)
    }

    @Test func thePRScreensFollowTheWorkersAIFeatures() async {
        let none = Self.model(DeviceConfig(features: [.push]))
        let session = none.session(for: PullRequestRef(repo: "acme/api", number: 7))
        #expect(!session.offersAsk && !session.offersKeyLines && !session.offersRewrite)
        #expect(session.keyLineItems.isEmpty)

        let all = Self.model(DeviceConfig(features: [.askAI, .keyLines, .rewrite]))
        let full = all.session(for: PullRequestRef(repo: "acme/api", number: 7))
        #expect(full.offersAsk && full.offersKeyLines && full.offersRewrite)
        #expect(!all.configuration.isOn(.push))
    }

    @Test func beforeTheFirstConfigEveryFeatureIsOff() {
        let model = Self.model(nil)
        for feature in [PRKitConfiguration.Feature.askAI, .keyLines, .rewrite, .push] {
            #expect(!model.configuration.isOn(feature))
        }
    }

    // MARK: - The org filter's default

    @Test func theFilterDefaultsToTheWorkersOrgsElseEveryOwner() {
        #expect(Self.model(DeviceConfig(features: [], orgs: ["acme", "beta"])).orgDefault == .orgs(["acme", "beta"]))
        #expect(Self.model(DeviceConfig(features: [], orgs: [])).orgDefault == .everyOwner)
        #expect(Self.model(DeviceConfig(features: [])).orgDefault == .everyOwner)
        #expect(Self.model(nil).orgDefault == .everyOwner)

        let owners = ["acme", "beta", "gamma"]
        #expect(PROrgDefault.orgs(["acme"]).filter(owners: owners).selected == ["acme"])
        #expect(PROrgDefault.everyOwner.filter(owners: owners).selected == Set(owners))
    }

    // MARK: - Pairing

    private static func connection(
        endpoint: WorkerEndpoint, config: DeviceConfig, unpaired: Shared<Int>, forgotten: Shared<Int>,
        defaults: UserDefaults = UserDefaults(suiteName: "prhub-tests-\(UUID().uuidString)")!,
        usage: UsageAnalytics = .disabled()
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
            defaults: defaults,
            build: PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: true, samples: true),
            usage: usage
        )
    }

    @Test func aPRWorkerAdmitsThePhoneAtOnceAndItsConfigIsReadBeforeThePRsShow() async throws {
        let endpoint = try Self.endpoint()
        let defaults = UserDefaults(suiteName: "prhub-tests-\(UUID().uuidString)")!
        let config = DeviceConfig(features: [.askAI, .push], login: "alex", orgs: ["acme"])
        let connection = Self.connection(
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
        let relaunched = Self.connection(
            endpoint: endpoint, config: config, unpaired: Shared(0), forgotten: Shared(0), defaults: defaults
        )
        #expect(relaunched.isPaired && relaunched.config == config)
        try endpoint.clear()
    }

    @Test func pairingAndDisconnectingAreRecordedWithoutTheWorker() async throws {
        let endpoint = try Self.endpoint()
        let sink = AnalyticsTests.RecordingAnalytics()
        let connection = Self.connection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0),
            usage: AnalyticsTests.usage(sink)
        )
        await connection.connect(text: "https://pr-review.alex.workers.dev")
        await connection.connect(text: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7kq2-m9xa")
        await connection.disconnect()
        #expect(sink.events == [
            .workerPairingFailed(.invalidLink), .onboardingPathChosen(.ownWorker), .workerPaired, .workerDisconnected,
        ])
    }

    @Test func aBadLinkSaysWhyAndPairsNothing() async throws {
        let endpoint = try Self.endpoint()
        let connection = Self.connection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        await connection.connect(text: "https://pr-review.alex.workers.dev")
        #expect(connection.phase == .invalidLink(.notASetupLink))
        await connection.connect(worker: "pr-review.alex.workers.dev", code: "7KQ2")
        #expect(connection.phase == .invalidLink(.badCode))
        #expect(endpoint.url == nil)
    }

    @Test func aLinkInAnotherSchemeIsNotFollowed() async throws {
        let endpoint = try Self.endpoint()
        let connection = Self.connection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        connection.open(URL(string: "agentpager://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9XA")!)
        #expect(connection.phase == .idle)
        #expect(!connection.isWorking)
        try endpoint.clear()
    }

    @Test func aLinkOpenedWhilePairedIsNotFollowed() async throws {
        let endpoint = try Self.endpoint()
        let connection = Self.connection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        await connection.connect(worker: "pr-review.alex.workers.dev", code: "7KQ2M9XA")
        connection.open(URL(string: "prhub://setup?worker=https%3A%2F%2Fother.example&code=7KQ2M9XA")!)
        #expect(connection.ignoredLinkHost == "pr-review.alex.workers.dev")
        #expect(connection.host == "pr-review.alex.workers.dev")
        try endpoint.clear()
    }

    @Test func disconnectTellsTheWorkerThenForgetsEverything() async throws {
        let endpoint = try Self.endpoint()
        let unpaired = Shared(0)
        let forgotten = Shared(0)
        let connection = Self.connection(
            endpoint: endpoint, config: DeviceConfig(features: [.push]), unpaired: unpaired, forgotten: forgotten
        )
        await connection.connect(worker: "pr-review.alex.workers.dev", code: "7KQ2M9XA")
        await connection.disconnect()
        #expect(unpaired.with { $0 } == 1)
        #expect(forgotten.with { $0 } == 1)
        #expect(connection.showsOnboarding && connection.config == nil && endpoint.url == nil)

        // Nothing is paired now: a second Disconnect tells nobody.
        await connection.disconnect()
        #expect(unpaired.with { $0 } == 1)
    }

    @Test func settingsSaysWhichAIFeaturesTheWorkerHas() {
        #expect(PRHubSettingsView.aiWords(DeviceConfig(features: [.askAI, .rewrite])) == "Ask AI, Rewrite")
        #expect(PRHubSettingsView.aiWords(DeviceConfig(features: [.push])) == "Off: no Anthropic key on the Worker")
    }
}
