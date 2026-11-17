import Foundation
@testable import PRHubCore
import Testing

struct DeviceConfigDecodeTests {
    private func decode(_ json: String) throws -> DeviceConfig {
        try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
    }

    @Test func readsAPRWorkersConfig() throws {
        let config = try decode("""
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

    @Test func aWorkerThatCouldNotAskGitHubHasNoLoginAndNoOrgs() throws {
        let config = try decode(#"{"features":{"push":"yes"},"login":null}"#)
        #expect(config.features.isEmpty)
        #expect(config.login == nil && config.orgs == nil)
    }

    @Test func settingsSaysWhichAIFeaturesTheWorkerHas() {
        #expect(DeviceConfig(features: [.askAI, .rewrite]).aiWords == "Ask AI, Rewrite")
        #expect(DeviceConfig(features: [.push]).aiWords == "Off: no Anthropic key on the Worker")
    }
}
