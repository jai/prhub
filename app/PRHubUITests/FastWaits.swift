import ObjectiveC
import XCTest

/// XCTest's `waitForExistence` and `waitForNonExistence` look once a second: each of the 341 waits in a phone run took
/// at least 0.9 s, 515 s of the run's 2,148 (GitHub's Mac, Xcode 27.2, 2026-11-14), though most of what they waited
/// for was there at once. This is the UI tests' principal class (`INFOPLIST_KEY_NSPrincipalClass` in project.yml),
/// made once as the bundle loads: it has both waits look at once and every 0.1 s for the first second, then hands what
/// is left of the timeout to XCTest's own wait. No test asks any differently.
final class FastWaits: NSObject {
    override init() {
        super.init()
        Self.quicken("waitForExistenceWithTimeout:", until: true)
        Self.quicken("waitForNonExistenceWithTimeout:", until: false)
    }

    private static let quick: TimeInterval = 1

    /// Replaces XCTest's wait `name` on `XCUIElement` (a BOOL from one timeout, in Xcode 26 and 27) with one that
    /// first looks itself until the element's `exists` is `wanted`.
    private static func quicken(_ name: String, until wanted: Bool) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(XCUIElement.self, selector) else {
            return
        }
        typealias Wait = @convention(c) (XCUIElement, Selector, TimeInterval) -> Bool
        let wait = unsafeBitCast(method_getImplementation(method), to: Wait.self)
        let quicker: @convention(block) (XCUIElement, TimeInterval) -> Bool = { element, timeout in
            // XCTest's waits are the main actor's, and so is every test that calls one.
            let end = Date().addingTimeInterval(min(timeout, quick))
            while MainActor.assumeIsolated({ element.exists }) != wanted {
                if Date() >= end {
                    return wait(element, selector, max(0, timeout - quick))
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return true
        }
        method_setImplementation(method, imp_implementationWithBlock(quicker))
    }
}
