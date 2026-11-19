import Foundation
@testable import PRKitCore
import Testing

/// Which folders the mirror uses (`PRMirrorLocation.library`): the app group's container's, else the app's own.
/// `PRKitIntegrationTests`' suite of this name moves real folders.
struct PRMirrorLocationTests {
    private let own = PRMirrorLocation.Library(
        caches: URL(filePath: "/own/Library/Caches"), support: URL(filePath: "/own/Library/Application Support")
    )

    @Test func aGroupWithNoContainerFallsBackToTheAppsOwnAndIsSaidOnce() {
        let group = "group.test.\(UUID().uuidString)"
        let library = PRMirrorLocation.library(appGroup: group, container: { _ in nil }, own: own)
        #expect(library == own)
        #expect(PRMirrorLocation.library(appGroup: nil, container: { _ in nil }, own: own) == own)
        #expect(!PRMirrorLocation.isFirstMiss(of: group), "the first miss was said already")
    }

    @Test func aGroupWithAContainerHoldsTheMirrorInItsApplicationSupport() {
        let container = URL(filePath: "/Group Containers/g", directoryHint: .isDirectory)
        let library = PRMirrorLocation.library(appGroup: "g", container: { _ in container }, own: own)
        #expect(library.support.path(percentEncoded: false) == "/Group Containers/g/Library/Application Support")
        #expect(library.caches.path(percentEncoded: false) == "/Group Containers/g/Library/Caches")
    }
}
