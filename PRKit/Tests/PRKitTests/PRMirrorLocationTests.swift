import Foundation
import Testing
@testable import PRKitCore

/// Where the mirror lives (`PRMirrorLocation`): the app group's container, else the app's own caches.
struct PRMirrorLocationTests {
    @Test func aGroupWithNoContainerFallsBackToTheCachesAndIsSaidOnce() {
        let group = "group.test.\(UUID().uuidString)"
        let directory = PRMirrorLocation.directory(appGroup: group, container: { _ in nil })
        #expect(directory == PRMirrorLocation.directory(appGroup: nil))
        #expect(!PRMirrorLocation.isFirstMiss(of: group), "the first miss was said already")
    }

    @Test func aGroupWithAContainerHoldsTheMirrorInItsCaches() {
        let container = URL.temporaryDirectory.appending(path: "Group Containers/g", directoryHint: .isDirectory)
        let directory = PRMirrorLocation.directory(appGroup: "g", container: { _ in container })
        #expect(directory == container.appending(path: "Library/Caches/pr-viewer", directoryHint: .isDirectory))
    }
}
