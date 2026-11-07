import PRKitNetwork
@testable import PRKit

extension PRTransport {
    /// A transport that never waits for a network, as in a background wake.
    static var background: PRTransport {
        PRTransport(isInForeground: { false })
    }
}
