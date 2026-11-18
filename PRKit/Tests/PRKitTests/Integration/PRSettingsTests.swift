import Foundation
@testable import PRKit
import Testing

@MainActor
struct PRSettingsTests {
    @Test func `sessions share their models preferences without changing another models settings`() {
        let first = TestPreferences()
        defer { withExtendedLifetime(first) {} }
        let second = TestPreferences()
        defer { withExtendedLifetime(second) {} }
        let storage = TestStorage()
        defer { withExtendedLifetime(storage) {} }
        let directory = storage.directory
        let client = PRViewerClient(access: .offline) { _ in throw URLError(.notConnectedToInternet) }
        let model = PRsModel(client: client, directory: directory, defaults: first.defaults,
                             network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)
        let other = PRsModel(client: client, directory: directory, defaults: second.defaults,
                             network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)
        let ref = PullRequestRef(repo: "settings/test", number: 1)

        let session = model.session(for: ref)
        session.setChangedLinesOnly(true)
        session.setContextLines(0)

        let reopened = model.session(for: ref)
        #expect(reopened.changedLinesOnly)
        #expect(reopened.contextLines == 0)
        #expect(!other.session(for: ref).changedLinesOnly)
        #expect(other.session(for: ref).contextLines == PRKeyLines.defaultContext)

        let relaunched = PRsModel(client: client, directory: directory, defaults: first.defaults,
                                  network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)
        #expect(relaunched.session(for: ref).changedLinesOnly)
        #expect(relaunched.session(for: ref).contextLines == 0)
    }

    @Test func `forgetting one models data keeps another models filter`() {
        let first = TestPreferences()
        defer { withExtendedLifetime(first) {} }
        let second = TestPreferences()
        defer { withExtendedLifetime(second) {} }
        first.defaults.set("acme|", forKey: "prOrgFilter")
        second.defaults.set("octocat|", forKey: "prOrgFilter")
        let storage = TestStorage()
        defer { withExtendedLifetime(storage) {} }
        let directory = storage.directory
        let client = PRViewerClient(access: .offline) { _ in throw URLError(.notConnectedToInternet) }
        let model = PRsModel(client: client, directory: directory, defaults: first.defaults,
                             network: PRNetwork(isOnline: true), draftDirectory: storage.draftDirectory)

        model.forgetEverything()

        #expect(first.defaults.object(forKey: "prOrgFilter") == nil)
        #expect(second.defaults.string(forKey: "prOrgFilter") == "octocat|")
    }
}
