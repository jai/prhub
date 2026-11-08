import XCTest

/// The app's places: its tabs, found by their accessibility identifiers (PRHubRootView). A phone shows them in the tab
/// bar at the bottom; an iPad's regular width shows them at the top, outside any tab bar. Tests reach a place with
/// `go(to:)` and never through `tabBars`.
enum PRHubPlace: String {
    case prs = "prhub-tab-prs"
    case settings = "prhub-tab-settings"
}

extension XCUIApplication {
    /// The place's tab item, on either idiom.
    @MainActor func tab(_ place: PRHubPlace) -> XCUIElement {
        descendants(matching: .any).matching(identifier: place.rawValue).firstMatch
    }

    /// Goes to `place` by its tab.
    @MainActor func go(to place: PRHubPlace) {
        let item = tab(place)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(place) tab")
        item.tap()
    }

    /// Back, by the navigation bar's back button; its first button where a bar has no `BackButton`.
    @MainActor func back() {
        let button = navigationBars.buttons["BackButton"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}

extension XCUIApplication {
    /// Launches PRHub in `appearance`. The app is told too (`-PRHubAppearance`): on CI's Simulator
    /// `XCUIDevice.shared.appearance` left the whole Simulator light.
    @MainActor func launch(_ arguments: [String], appearance: XCUIDevice.Appearance) {
        terminate()
        XCUIDevice.shared.appearance = appearance
        launchArguments = arguments + ["-PRHubAppearance", appearance == .dark ? "dark" : "light"]
        launch()
    }
}

extension XCUIApplication {
    /// Scrolls Settings until `element` can be tapped, then waits for the page to stop: a tap on a page still moving
    /// only stops it.
    @MainActor func scrollSettings(to element: XCUIElement, up: Bool = true) -> Bool {
        let page = scrollViews["prhub-settings"]
        for _ in 0..<10 where !isClearOfBars(element) {
            if up {
                page.swipeUp(velocity: .slow)
            } else {
                page.swipeDown(velocity: .slow)
            }
        }
        var frame = element.frame
        for _ in 0..<10 {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
            if element.frame == frame {
                break
            }
            frame = element.frame
        }
        return isClearOfBars(element)
    }

    /// On screen and out from under the nav bar and the tab bar, which take a tap meant for what scrolls under them.
    @MainActor private func isClearOfBars(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else {
            return false
        }
        let top = navigationBars.firstMatch.exists ? navigationBars.firstMatch.frame.maxY : 0
        let bottom = tabBars.firstMatch.exists ? tabBars.firstMatch.frame.minY : frame.maxY
        return element.frame.minY >= top && element.frame.maxY <= bottom
    }
}
