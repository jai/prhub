import Foundation
import Security
import Synchronization

/// The pr-worker's URL, learnt from a setup link (docs/api.md, "Pairing"), kept in the Keychain beside the
/// device secret: the same service (`AppIdentity.bundleID`), its own account, and the same accessibility class, so a
/// locked background wake after the first unlock can still reach the Worker. Never migrated in a backup: a restored
/// phone pairs again, as it has a new device secret.
struct WorkerURLStore: Sendable {
    let service: String
    let account: String

    static let live = WorkerURLStore(service: AppIdentity.bundleID, account: "worker-url")

    func load() throws(DeviceSecretStore.Failure) -> URL? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8), let url = URL(string: text)
            else {
                throw .corruptItem
            }
            return url
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    func save(_ url: URL) throws(DeviceSecretStore.Failure) {
        let data = Data(url.absoluteString.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else {
            throw .keychain(update)
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .keychain(status)
        }
    }

    func delete() throws(DeviceSecretStore.Failure) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
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
}

/// Where every request goes, read per request: the URL the setup link gave, from the Keychain, or `nil` until a setup
/// link has paired the phone, and then every request fails as `notPaired` before anything is sent. The samples have a
/// fixed one that nothing is sent to.
final class WorkerEndpoint: Sendable {
    static let live = WorkerEndpoint(store: .live)

    private enum State {
        /// Not read yet, or the Keychain could not be read the last time (a wake before the first unlock).
        case unread
        case read(URL?)
    }

    private let fixed: URL?
    private let store: WorkerURLStore?
    private let state: Mutex<State>

    init(fixed: URL) {
        self.fixed = fixed
        store = nil
        state = Mutex(.read(fixed))
    }

    init(store: WorkerURLStore) {
        fixed = nil
        self.store = store
        state = Mutex(.unread)
    }

    var url: URL? {
        if let fixed {
            return fixed
        }
        guard let store else {
            return nil
        }
        return state.withLock { state in
            if case .read(let url) = state {
                return url
            }
            do {
                let loaded = try store.load()
                state = .read(loaded)
                return loaded
            } catch {
                return nil
            }
        }
    }

    /// Saves a paired Worker. A fixed one has nothing to save.
    func save(_ url: URL) throws(DeviceSecretStore.Failure) {
        guard let store else {
            return
        }
        try store.save(url)
        state.withLock { $0 = .read(url) }
    }

    /// Forgets the Worker: Settings' Disconnect.
    func clear() throws(DeviceSecretStore.Failure) {
        guard let store else {
            return
        }
        try store.delete()
        state.withLock { $0 = .read(nil) }
    }
}
