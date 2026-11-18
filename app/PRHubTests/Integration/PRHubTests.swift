import Foundation
import PRContractFixtures
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing

private let prHubSecret = "prhub-device-secret-0123456789"

/// PRHub's requests go to the paired pr-worker with the device secret as the bearer, the PR screens follow its
/// `GET /device/config` (docs/api.md), and pairing needs nothing after `POST /device/pair`.
@MainActor
struct PRHubTests {
    private let resources = IntegrationResources()
    private func makeModel(_ config: DeviceConfig?) -> PRsModel {
        let model = PRsModel(client: PRViewerClient(access: .paired(
            endpoint: WorkerEndpoint(fixed: URL(string: "https://pr-review.alex.workers.dev")!), secret: { prHubSecret }
        )), directory: resources.directory(), defaults: resources.defaults(),
        network: PRNetwork(isOnline: true), draftDirectory: resources.directory())
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    // MARK: - Where requests go

    @Test func aPairedRequestGoesToThePairedWorkerWithTheDeviceSecret() async throws {
        let endpoint = try resources.endpoint(saving: "https://pr-review.alex.workers.dev")
        let client = PRViewerClient(access: .paired(endpoint: endpoint, secret: { prHubSecret }))
        let request = try await client.outboxRequest(path: "prs/acme/api/7/write", body: Data("{}".utf8))
        #expect(request.url?.host() == "pr-review.alex.workers.dev")
        #expect(request.url?.path() == "/prs/acme/api/7/write")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(prHubSecret)")
        try endpoint.clear()
    }

    @Test func beforePairingNothingIsBuilt() async throws {
        let endpoint = try resources.endpoint()
        let client = PRViewerClient(access: .paired(endpoint: endpoint, secret: { prHubSecret }))
        await #expect(throws: PRWorkerError.notPaired) {
            try await client.outboxRequest(path: "prs", body: Data())
        }
    }

    // MARK: - `GET /device/config`

    @Test func theWorkersFixtureDecodes() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: ContractFixtures.data("device-config.json"))
        #expect(config.features == [.keyLines, .rewrite, .push])
        #expect(config.login == "alex" && config.orgs == ["acme"])
        #expect(config.appLatest?.build(for: .internal) == AppBuild(version: "1.0", build: "212"))
        #expect(config.appLatest?.build(for: .public) == AppBuild(version: "1.0", build: "198"))
    }

    @Test func thePRScreensFollowTheWorkersAIFeatures() {
        let none = makeModel(DeviceConfig(features: [.push]))
        let session = none.session(for: PullRequestRef(repo: "acme/api", number: 7))
        #expect(!session.offersAsk && !session.offersKeyLines && !session.offersRewrite)
        #expect(session.keyLineItems.isEmpty)

        let all = makeModel(DeviceConfig(features: [.askAI, .keyLines, .rewrite]))
        let full = all.session(for: PullRequestRef(repo: "acme/api", number: 7))
        #expect(full.offersAsk && full.offersKeyLines && full.offersRewrite)
        #expect(!all.configuration.isOn(.push))
    }

    @Test func beforeTheFirstConfigEveryFeatureIsOff() {
        let model = makeModel(nil)
        for feature in [PRKitConfiguration.Feature.askAI, .keyLines, .rewrite, .push] {
            #expect(!model.configuration.isOn(feature))
        }
    }

    // MARK: - The org filter's default

    @Test func theFilterDefaultsToTheWorkersOrgsElseEveryOwner() {
        #expect(makeModel(DeviceConfig(features: [], orgs: ["acme", "beta"])).orgDefault == .orgs(["acme", "beta"]))
        #expect(makeModel(DeviceConfig(features: [], orgs: [])).orgDefault == .everyOwner)
        #expect(makeModel(DeviceConfig(features: [])).orgDefault == .everyOwner)
        #expect(makeModel(nil).orgDefault == .everyOwner)

        let owners = ["acme", "beta", "gamma"]
        #expect(PROrgDefault.orgs(["acme"]).filter(owners: owners).selected == ["acme"])
        #expect(PROrgDefault.everyOwner.filter(owners: owners).selected == Set(owners))
    }

    // MARK: - Pairing

    private func makeConnection(
        endpoint: WorkerEndpoint, config: DeviceConfig, unpaired: Shared<Int>, forgotten: Shared<Int>,
        defaults: UserDefaults? = nil, usage: UsageAnalytics? = nil
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
            usage: usage ?? resources.usage()
        )
    }

    @Test func aPRWorkerAdmitsThePhoneAtOnceAndItsConfigIsReadBeforeThePRsShow() async throws {
        let endpoint = try resources.endpoint()
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
            endpoint: endpoint, config: config, unpaired: Shared(0), forgotten: Shared(0), defaults: defaults
        )
        #expect(relaunched.isPaired && relaunched.config == config)
        try endpoint.clear()
    }

    @Test func pairingAndDisconnectingAreRecordedWithoutTheWorker() async throws {
        let endpoint = try resources.endpoint()
        let sink = AnalyticsTests.RecordingAnalytics()
        let connection = makeConnection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0),
            usage: resources.usage(sink)
        )
        await connection.connect(text: "https://pr-review.alex.workers.dev")
        await connection.connect(text: "prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7kq2-m9xa")
        await connection.disconnect()
        #expect(sink.events == [
            .workerPairingFailed(.invalidLink), .onboardingPathChosen(.ownWorker), .workerPaired, .workerDisconnected,
        ])
    }

    @Test func aBadLinkSaysWhyAndPairsNothing() async throws {
        let endpoint = try resources.endpoint()
        let connection = makeConnection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        await connection.connect(text: "https://pr-review.alex.workers.dev")
        #expect(connection.phase == .invalidLink(.notASetupLink))
        await connection.connect(worker: "pr-review.alex.workers.dev", code: "7KQ2")
        #expect(connection.phase == .invalidLink(.badCode))
        #expect(endpoint.url == nil)
    }

    @Test func aLinkInAnotherSchemeIsNotFollowed() throws {
        let endpoint = try resources.endpoint()
        let connection = makeConnection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        try connection.open(#require(URL(string: "agentpager://setup?worker=https%3A%2F%2Fa.example&code=7KQ2M9XA")))
        #expect(connection.phase == .idle)
        #expect(!connection.isWorking)
        try endpoint.clear()
    }

    @Test func aLinkOpenedWhilePairedIsNotFollowed() async throws {
        let endpoint = try resources.endpoint()
        let connection = makeConnection(
            endpoint: endpoint, config: DeviceConfig(features: []), unpaired: Shared(0), forgotten: Shared(0)
        )
        await connection.connect(worker: "pr-review.alex.workers.dev", code: "7KQ2M9XA")
        try connection.open(#require(URL(string: "prhub://setup?worker=https%3A%2F%2Fother.example&code=7KQ2M9XA")))
        #expect(connection.ignoredLinkHost == "pr-review.alex.workers.dev")
        #expect(connection.host == "pr-review.alex.workers.dev")
        try endpoint.clear()
    }

    @Test func disconnectTellsTheWorkerThenForgetsEverything() async throws {
        let endpoint = try resources.endpoint()
        let unpaired = Shared(0)
        let forgotten = Shared(0)
        let connection = makeConnection(
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
}
