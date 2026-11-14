import Foundation
import PRKitNetwork
@testable import PRKit

/// The worker's golden fixtures (docs/fixtures/), read from the repo. Xcode Cloud's test Mac has the built products and
/// no sources, so the tests that read them run only where the repo is: `swift test` anywhere, and in Xcode Cloud from
/// app/ci_scripts/ci_post_clone.sh, which runs on the Mac with the sources.
enum RepoFixtures {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../docs/fixtures").standardized

    static var areHere: Bool {
        FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appending(path: name))
    }
}

extension PRTransport {
    /// A transport that never waits for a network, as in a background wake.
    static var background: PRTransport {
        PRTransport(isInForeground: { false })
    }
}
