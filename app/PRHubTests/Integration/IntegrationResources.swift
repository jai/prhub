import Foundation
@testable import PRHubCore
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

    /// A Keychain entry of its own, removed when the test ends.
    func keychain() -> WorkerURLStore {
        let store = WorkerURLStore(service: "com.jaigovindani.prreview.tests", account: UUID().uuidString)
        keychains.append(store)
        return store
    }

    @MainActor func usage() -> UsageAnalytics {
        UsageAnalytics(hasProject: false, sink: nil, defaults: defaults())
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
