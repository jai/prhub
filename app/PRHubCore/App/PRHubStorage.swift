import Foundation
import PRKit
import PRKitCore

/// What an environment keeps on the device: the PR screens' mirror, answers, drafts and list settings, the samples' own
/// copy of those, and the samples' Worker config. On the phone, folders and `UserDefaults`; in a unit test, memory.
public struct PRHubStorage {
    /// The PR screens' storage. Its `settings` are also the alert offer's and Update available's.
    public var prs: PRKitStorage
    /// The samples' PR screens' storage, made each time "Try with sample PRs" starts. Its settings are `prs`' settings, so
    /// leaving the samples clears their list settings there.
    public var samples: () -> PRKitStorage
    /// The samples' Worker config and their Update available.
    public var sampleConfiguration: any PRKeyValueStore

    public init(
        prs: PRKitStorage, samples: @escaping () -> PRKitStorage, sampleConfiguration: any PRKeyValueStore
    ) {
        self.prs = prs
        self.samples = samples
        self.sampleConfiguration = sampleConfiguration
    }

    /// The samples' own: their PR screens' storage in place of `prs`.
    func forSamples() -> PRHubStorage {
        PRHubStorage(prs: samples(), samples: samples, sampleConfiguration: sampleConfiguration)
    }
}

public extension PRHubStorage {
    /// The app's: the mirror in the app group, the samples' in the caches, drafts in Application Support.
    static func live(defaults: UserDefaults, sampleConfiguration: UserDefaults) -> PRHubStorage {
        PRHubStorage(
            prs: .onDisk(directory: PRHubPRHost.mirrorDirectory(), defaults: defaults),
            samples: { .onDisk(directory: PRKitStorage.defaultDirectory(samples: .prHub), defaults: defaults) },
            sampleConfiguration: sampleConfiguration
        )
    }

    /// A fixture launch's: everything under `directory`, the samples' under its `samples` folder.
    static func onDisk(directory: URL, defaults: UserDefaults, sampleConfiguration: UserDefaults) -> PRHubStorage {
        func folders(_ root: URL) -> PRKitStorage {
            .onDisk(
                directory: root.appending(path: "mirror"), draftDirectory: root.appending(path: "drafts"),
                defaults: defaults
            )
        }
        return PRHubStorage(
            prs: folders(directory), samples: { folders(directory.appending(path: "samples")) },
            sampleConfiguration: sampleConfiguration
        )
    }
}
