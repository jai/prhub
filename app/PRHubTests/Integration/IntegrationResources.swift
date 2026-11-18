import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

final class IntegrationResources {
    private let root = URL.temporaryDirectory.appending(path: "prhub-integration-\(UUID().uuidString)")
    private var domains: [String] = []
    private var keychains: [WorkerURLStore] = []

    func directory(_ name: String = UUID().uuidString) -> URL {
        root.appending(path: name)
    }

    func defaults() -> UserDefaults {
        let domain = "prhub-integration-\(UUID().uuidString)"
        domains.append(domain)
        return UserDefaults(suiteName: domain)!
    }

    func endpoint(saving address: String? = nil) throws -> WorkerEndpoint {
        let store = WorkerURLStore(service: "com.jaigovindani.prreview.tests", account: UUID().uuidString)
        keychains.append(store)
        let endpoint = WorkerEndpoint(store: store)
        if let address {
            try endpoint.save(#require(URL(string: address)))
        }
        return endpoint
    }

    @MainActor func usage(_ sink: (any Analytics)? = nil) -> UsageAnalytics {
        UsageAnalytics(hasProject: sink != nil, sink: sink, defaults: defaults())
    }

    @MainActor func sample(usage: UsageAnalytics? = nil, defaults: UserDefaults? = nil) -> PRHubEnvironment {
        PRHubEnvironment.sample(
            usage: usage ?? self.usage(), defaults: defaults ?? self.defaults(),
            configurationDefaults: self.defaults(), storageDirectory: directory(), network: PRNetwork(isOnline: true)
        )
    }

    @MainActor func environment(usage: UsageAnalytics? = nil, defaults: UserDefaults? = nil) -> PRHubEnvironment {
        PRHubEnvironment(
            connection: sample().connection, usage: usage ?? self.usage(), defaults: defaults ?? self.defaults(),
            sampleDefaults: self.defaults(), storageDirectory: directory(), network: PRNetwork(isOnline: true)
        )
    }

    deinit {
        for domain in domains {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        for store in keychains {
            do { try store.delete() } catch { Issue.record(error, "could not remove test Keychain entry") }
        }
        if FileManager.default.fileExists(atPath: root.path()) {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error, "could not remove test directory") }
        }
    }
}
