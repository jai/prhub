import CryptoKit
import Foundation
import Security

/// This phone's identity with its pr-worker: 32 random bytes, base64url, generated once and kept in the Keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable in a locked background wake after the first unlock,
/// never migrated in a backup, so a restored phone pairs again as a new device. It is the bearer of every request.
struct DeviceSecretStore: Sendable {
    enum Failure: Error, Equatable {
        case randomBytesFailed(Int32)
        case keychain(OSStatus)
        case corruptItem
        /// No secret could be read and this is not a moment to create one (see `loadOrCreate`).
        case protectedDataUnavailable
    }

    let service: String
    let account: String
    /// `UIApplication.isProtectedDataAvailable` in the app; injected so the rule below can be tested.
    let isProtectedDataAvailable: @Sendable () -> Bool

    init(service: String, account: String, isProtectedDataAvailable: @escaping @Sendable () -> Bool) {
        self.service = service
        self.account = account
        self.isProtectedDataAvailable = isProtectedDataAvailable
    }

    static func live(isProtectedDataAvailable: @escaping @Sendable () -> Bool) -> DeviceSecretStore {
        DeviceSecretStore(
            service: AppIdentity.bundleID,
            account: "device-secret",
            isProtectedDataAvailable: isProtectedDataAvailable
        )
    }

    /// Returns the stored secret, creating and storing one on first use.
    ///
    /// "Not found" is only believed while protected data is available. A keychain that cannot decrypt yet (a wake
    /// before the first unlock) has been seen to answer not-found; minting a secret then would unpair the phone.
    func loadOrCreate() throws -> String {
        if let existing = try load() {
            return existing
        }
        guard isProtectedDataAvailable() else {
            throw Failure.protectedDataUnavailable
        }
        let secret = try Self.generateSecret()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return secret
        case errSecDuplicateItem:
            // Lost a race with another writer; the stored item wins.
            guard let stored = try load() else {
                throw Failure.keychain(status)
            }
            return stored
        default:
            throw Failure.keychain(status)
        }
    }

    /// SHA-256 of the secret exactly as it is sent in the bearer, as 64 lowercase hex characters: what the Worker keys
    /// this device by.
    static func fingerprint(of secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw Failure.corruptItem
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    /// Removes the item: test cleanup, and Disconnect (`WorkerConnection.disconnect`), after which the next pairing is
    /// a new device.
    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// 32 random bytes → 43 base64url characters without padding.
    static func generateSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Failure.randomBytesFailed(status)
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
