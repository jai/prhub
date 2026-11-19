import DurableNetworking
import Foundation
import PRKitCore

/// Everything the PR screens keep on the device: the mirror's files (`PRMirror`), the last good answers beside them
/// (`PRsModel.kept`), the line comments not yet sent (`PRDraftStore`) and the model's settings. On the phone it is
/// `onDisk`; a unit test passes stores in memory.
public struct PRKitStorage {
    public var mirror: any PRFileStore
    public var kept: any PRKeptStore
    public var drafts: any PRFileStore
    public var settings: any PRKeyValueStore
    /// The folder `kept` writes to, where a host keeps its own reads beside it (FeatureKit's `keptIn`): the mirror's
    /// prune spares it and Disconnect clears it. Nil when nothing is on disk.
    public var keptFolder: URL?

    public init(
        mirror: any PRFileStore, kept: any PRKeptStore, drafts: any PRFileStore, settings: any PRKeyValueStore,
        keptFolder: URL? = nil
    ) {
        self.mirror = mirror
        self.kept = kept
        self.drafts = drafts
        self.settings = settings
        self.keptFolder = keptFolder
    }

    /// The mirror in `directory` with the kept answers in its `kept` folder, the drafts in `draftDirectory` (Application
    /// Support's `pr-drafts` when nil) and the settings in `defaults`.
    public static func onDisk(
        directory: URL, draftDirectory: URL? = nil, defaults: any PRKeyValueStore = UserDefaults.standard
    ) -> Self {
        let keptFolder = directory.appending(path: PRMirror.keptFolder, directoryHint: .isDirectory)
        return PRKitStorage(
            mirror: PRDiskFileStore(directory: directory), kept: ReadStore(directory: keptFolder),
            drafts: PRDiskFileStore(directory: draftDirectory ?? PRDraftStore.defaultDirectory), settings: defaults,
            keptFolder: keptFolder
        )
    }

    /// The mirror's folder when the host names none: the app's caches, one for the samples and one for a Worker's PRs.
    public static func defaultDirectory(samples: PRSampleSet?) -> URL {
        let name = samples == nil ? "pr-viewer" : PRSampleSet.directoryName
        return URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory)
    }
}
