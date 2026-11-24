import Foundation
@testable import PRHubCore
@testable import PRKit
import PRKitTestSupport
import Synchronization
import Testing

/// The paired Worker's URL in memory, where the app keeps it in the Keychain.
final class InMemoryWorkerURLStore: WorkerURLStoring {
    private let url = Mutex<URL?>(nil)

    func load() throws(DeviceSecretStore.Failure) -> URL? {
        url.withLock { $0 }
    }

    func save(_ url: URL) throws(DeviceSecretStore.Failure) {
        self.url.withLock { $0 = url }
    }

    func delete() throws(DeviceSecretStore.Failure) {
        url.withLock { $0 = nil }
    }
}

/// What a unit test hands PRHub's models in place of the device's: settings, the Worker's URL and the PR screens' files,
/// all in memory.
@MainActor
struct UnitResources {
    /// A build that offers the samples and nothing else, so no test reads the test runner's own Info.plist.
    static let build = PRHubBuild(hostedURL: nil, signInWithGitHub: false, selfHosted: false, samples: true)

    func defaults() -> InMemoryKeyValueStore {
        InMemoryKeyValueStore()
    }

    func endpoint(saving address: String? = nil) throws -> WorkerEndpoint {
        let endpoint = WorkerEndpoint(store: InMemoryWorkerURLStore())
        if let address {
            try endpoint.save(#require(URL(string: address)))
        }
        return endpoint
    }

    func usage(_ sink: (any Analytics)? = nil) -> UsageAnalytics {
        UsageAnalytics(hasProject: sink != nil, sink: sink, defaults: defaults())
    }

    /// The PR screens' storage and the samples', both over `settings`, as on the phone.
    func storage(settings: InMemoryKeyValueStore = InMemoryKeyValueStore()) -> PRHubStorage {
        PRHubStorage(
            prs: .inMemory(settings: settings), samples: { .inMemory(settings: settings) },
            sampleConfiguration: InMemoryKeyValueStore()
        )
    }

    /// Alerts the system has not been asked about, and never is.
    func alertPermission(defaults: InMemoryKeyValueStore) -> PRHubAlertPermission {
        PRHubAlertPermission(center: .init(status: { .notDetermined }, request: { false }), defaults: defaults)
    }

    /// "Try with sample PRs" on its own.
    func sample(usage: UsageAnalytics? = nil, defaults: InMemoryKeyValueStore? = nil) -> PRHubEnvironment {
        let settings = defaults ?? self.defaults()
        return PRHubEnvironment.sample(
            usage: usage ?? self.usage(), storage: storage(settings: settings), build: Self.build,
            alertPermission: alertPermission(defaults: settings), network: PRNetwork(isOnline: true)
        )
    }

    /// As if paired with a Worker that serves `features`, with nothing sent to it.
    func paired(features: Set<DeviceFeature>) -> PRHubEnvironment {
        let settings = defaults()
        return PRHubEnvironment.offline(
            config: DeviceConfig(features: features, login: "octocat"), isSample: false, usage: usage(),
            storage: storage(settings: settings), build: Self.build,
            alertPermission: alertPermission(defaults: settings), network: PRNetwork(isOnline: true)
        )
    }

    /// A paired environment over the samples' connection, from which the samples can start.
    func environment(usage: UsageAnalytics? = nil, defaults: InMemoryKeyValueStore? = nil) -> PRHubEnvironment {
        let settings = defaults ?? self.defaults()
        return PRHubEnvironment(
            connection: sample().connection, storage: storage(settings: settings),
            alertPermission: alertPermission(defaults: settings), usage: usage ?? self.usage(),
            network: PRNetwork(isOnline: true)
        )
    }
}
