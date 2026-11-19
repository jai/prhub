import DurableNetworking
import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// The model's settings (`PRsModel.settings`): each model's own store, read again by the next launch's model.
@MainActor
struct PRSettingsTests {
    private let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())

    private func model(_ settings: InMemoryKeyValueStore) -> PRsModel {
        PRsModel(client: client, storage: .inMemory(settings: settings), network: PRNetwork(isOnline: true))
    }

    @Test func `sessions share their models preferences without changing another models settings`() {
        let first = InMemoryKeyValueStore()
        let model = self.model(first)
        let other = self.model(InMemoryKeyValueStore())
        let ref = PullRequestRef(repo: "settings/test", number: 1)

        let session = model.session(for: ref)
        session.setChangedLinesOnly(true)
        session.setContextLines(0)

        let reopened = model.session(for: ref)
        #expect(reopened.changedLinesOnly)
        #expect(reopened.contextLines == 0)
        #expect(!other.session(for: ref).changedLinesOnly)
        #expect(other.session(for: ref).contextLines == PRKeyLines.defaultContext)

        let relaunched = self.model(first)
        #expect(relaunched.session(for: ref).changedLinesOnly)
        #expect(relaunched.session(for: ref).contextLines == 0)
    }

    @Test func `forgetting one models data keeps another models filter`() {
        let first = InMemoryKeyValueStore()
        let second = InMemoryKeyValueStore()
        first.set("acme|", forKey: "prOrgFilter")
        second.set("octocat|", forKey: "prOrgFilter")
        let model = self.model(first)
        _ = self.model(second)

        model.forgetEverything()

        #expect(first.object(forKey: "prOrgFilter") == nil)
        #expect(second.object(forKey: "prOrgFilter") as? String == "octocat|")
    }
}
