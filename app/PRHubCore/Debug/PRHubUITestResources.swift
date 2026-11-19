#if DEBUG
    import Foundation
    import UserNotifications

    /// A fixture launch's storage, kept apart from the app's own: its preferences, files and Keychain entry. Each fixture
    /// launch starts empty. `-PRHubKeepState` keeps what the previous launch left, for a test that relaunches on purpose.
    @MainActor
    public final class PRHubUITestResources {
        /// The launch arguments that run the app over a fixture instead of the person's own Worker.
        public nonisolated static let fixtureModes = ["-PRHubFirstRun", "-PRHubPaired", "-PRHubHosted", "-PRHubStubWorker", "-PRHubOutboxCheck"]

        public nonisolated static var isFixtureLaunch: Bool {
            ProcessInfo.processInfo.arguments.contains(where: fixtureModes.contains)
        }

        public static let current: PRHubUITestResources? = {
            guard isFixtureLaunch else { return nil }
            let resources = PRHubUITestResources()
            if ProcessInfo.processInfo.arguments.contains("-PRHubKeepState") {
                resources.isFresh = false
            } else {
                resources.reset()
            }
            try? FileManager.default.createDirectory(at: resources.directory, withIntermediateDirectories: true)
            return resources
        }()

        private static let name = "prhub-ui-test"

        /// False when `-PRHubKeepState` kept the previous launch's storage.
        private(set) var isFresh = true
        public let defaults = UserDefaults(suiteName: name)!
        let configurationDefaults = UserDefaults(suiteName: "\(name).configuration")!
        let sampleDefaults = UserDefaults(suiteName: "\(name).samples")!
        let directory = URL.applicationSupportDirectory.appending(path: name)
        let endpointStore = WorkerURLStore(service: AppIdentity.bundleID + ".ui-tests", account: "url")

        private init() {}

        private func reset() {
            try? endpointStore.delete()
            defaults.removePersistentDomain(forName: Self.name)
            configurationDefaults.removePersistentDomain(forName: "\(Self.name).configuration")
            sampleDefaults.removePersistentDomain(forName: "\(Self.name).samples")
            try? FileManager.default.removeItem(at: directory)
        }

        /// The fixture's folders and preferences; the samples' Worker config in `sampleConfiguration`, else the
        /// fixture's own config's.
        func storage(sampleConfiguration: UserDefaults? = nil) -> PRHubStorage {
            .onDisk(
                directory: directory, defaults: defaults, sampleConfiguration: sampleConfiguration ?? configurationDefaults
            )
        }

        func alertPermission() -> PRHubAlertPermission {
            PRHubAlertPermission(center: .init(status: { .denied }, request: { false }), defaults: defaults)
        }

        func isolateAlerts(in environment: PRHubEnvironment) {
            environment.readDeliveredAlerts = { [] }
        }
    }
#endif
