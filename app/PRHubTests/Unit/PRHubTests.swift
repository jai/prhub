@testable import PRHubCore
@testable import PRKit
import PRKitTestSupport
import Testing

/// The PR screens follow the Worker's `GET /device/config` (docs/api.md): its features, and where the org filter starts.
@MainActor
struct PRHubTests {
    private func makeModel(_ config: DeviceConfig?) -> PRsModel {
        let model = PRsModel(
            client: PRViewerClient(access: .offline, transport: UnexpectedTransport()), storage: .inMemory(),
            network: PRNetwork(isOnline: true)
        )
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    // MARK: - `GET /device/config`

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
}
