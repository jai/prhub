import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

/// Where PRHub keeps things on the device: a fixture's folder (`PRHubStorage.onDisk`) and the paired Worker's URL in the
/// Keychain (`WorkerURLStore`).
@MainActor
struct PRHubStorageTests {
    private let resources = IntegrationResources()

    /// "Try with sample PRs" from a paired environment: the samples' files go in their own folder, never the Worker's
    /// mirror, and leaving them clears their list settings from the preferences the list shares.
    @Test func theSamplesKeepTheirFilesApartAndLeaveNoListSettingBehind() throws {
        let directory = resources.directory()
        let defaults = resources.defaults()
        let storage = PRHubStorage.onDisk(directory: directory, defaults: defaults, sampleConfiguration: resources.defaults())
        let build = PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: true, samples: true)
        let connection = PRHubEnvironment.sample(
            usage: resources.usage(), storage: storage, build: build,
            alertPermission: resources.alertPermission(defaults: defaults), network: PRNetwork(isOnline: true)
        ).connection
        let environment = PRHubEnvironment(
            connection: connection, storage: storage, alertPermission: resources.alertPermission(defaults: defaults),
            usage: resources.usage(), network: PRNetwork(isOnline: true)
        )
        let paired = Set(Self.names(in: directory.appending(path: "mirror")))

        environment.startSample()
        let row = try #require(environment.sample?.prs.model.rows.first)
        let sampleMirror = Self.names(in: directory.appending(path: "samples/mirror"))
        #expect(sampleMirror.contains(row.detailFileName), "the samples' files, in their own folder")
        #expect(Set(Self.names(in: directory.appending(path: "mirror"))) == paired, "the Worker's mirror untouched")

        defaults.set("acme,octocat|", forKey: "prOrgFilter")
        environment.endSample()
        #expect(defaults.object(forKey: "prOrgFilter") == nil)
    }

    @Test func theWorkersURLIsKeptInTheKeychainUntilDeleted() throws {
        let store = resources.keychain()
        #expect(try store.load() == nil)
        let first = try #require(URL(string: "https://pr-review.alex.workers.dev"))
        try store.save(first)
        #expect(try store.load() == first)
        let second = try #require(URL(string: "https://pr-review.acme.workers.dev"))
        try store.save(second)
        #expect(try store.load() == second, "a second save replaces the first")
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    private static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
    }
}
