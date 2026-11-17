import DurableNetworking
import Foundation
@testable import PRKit

extension URLSessionTransport {
    /// A transport that never waits for a network, as in a background wake.
    static var background: URLSessionTransport {
        URLSessionTransport(policy: .quick)
    }
}

/// An isolated preferences domain, removed when its test finishes.
final class TestPreferences {
    private let name = "prkit-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
