import Foundation
@testable import PRHubCore
import Testing

/// The session secret in the Keychain.
struct HostedConfigTests {
    @Test func theSessionSecretIsKeptWhereTheDeviceSecretIs() throws {
        let store = DeviceSecretStore(
            service: "com.jaigovindani.prreview.tests", account: "session-\(UUID().uuidString)",
            isProtectedDataAvailable: { true }
        )
        defer {
            do { try store.delete() } catch { Issue.record(error, "could not remove test session secret") }
        }
        try store.save("4242.first")
        #expect(try store.load() == "4242.first")
        try store.save("4242.second")
        #expect(try store.loadOrCreate() == "4242.second")
        try store.delete()
        #expect(try store.load() == nil)
    }
}
