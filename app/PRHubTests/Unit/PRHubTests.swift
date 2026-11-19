@testable import PRHubCore
import PRKit
import Testing

@MainActor
struct PRHubTests {
    @Test func thePRHostMapsTheWorkersAIFeatures() {
        let none = PRHubPRHost.configuration(DeviceConfig(features: [.push]))
        #expect(none.features == [.push])
        let all = PRHubPRHost.configuration(DeviceConfig(features: [.askAI, .keyLines, .rewrite]))
        #expect(all.features == [.askAI, .keyLines, .rewrite])
    }

    @Test func beforeTheFirstConfigEveryFeatureIsOff() {
        #expect(PRHubPRHost.configuration(nil).features.isEmpty)
    }

    @Test func theFilterDefaultsToTheWorkersOrgsElseEveryOwner() {
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [], orgs: ["acme", "beta"])).orgDefault
            == .orgs(["acme", "beta"]))
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [], orgs: [])).orgDefault == .everyOwner)
        #expect(PRHubPRHost.configuration(DeviceConfig(features: [])).orgDefault == .everyOwner)
        #expect(PRHubPRHost.configuration(nil).orgDefault == .everyOwner)
    }
}
