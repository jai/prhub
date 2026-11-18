import XCTest

/// The app's places: its tabs, found by their accessibility identifiers (PRHubRootView). A phone shows them in the tab
/// bar at the bottom; an iPad's regular width shows them at the top, outside any tab bar. Tests reach a place with
/// `go(to:)` and never through `tabBars`.
enum PRHubPlace: String {
    case prs = "prhub-tab-prs"
    case settings = "prhub-tab-settings"
}

@MainActor
extension XCUIApplication {
    /// The place's tab item, on either idiom.
    func tab(_ place: PRHubPlace) -> XCUIElement {
        descendants(matching: .any).matching(identifier: place.rawValue).firstMatch
    }

    /// Goes to `place` by its tab.
    func go(to place: PRHubPlace) {
        let item = tab(place)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(place) tab")
        item.tap()
    }

    /// Back, by the navigation bar's back button; its first button where a bar has no `BackButton`.
    func back() {
        let button = navigationBars.buttons["BackButton"]
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}

@MainActor
extension XCUIApplication {
    /// Closes the diff's panel where it is over the code (a compact width), by a tap on the dim beside it. A column
    /// beside the code (a regular width) stays.
    func closePanelOverDiff() {
        guard windows.firstMatch.horizontalSizeClass != .regular,
              buttons["key-lines-context-100"].waitForExistence(timeout: 3)
        else {
            return
        }
        coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        let panel = buttons["key-lines-context-100"]
        for _ in 0 ..< 20 where panel.exists {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
    }
}

@MainActor
extension XCUIApplication {
    /// Launches PRHub in `appearance`. The app is told too (`-PRHubAppearance`): on CI's Simulator
    /// `XCUIDevice.shared.appearance` left the whole Simulator light.
    func launch(_ arguments: [String], appearance: XCUIDevice.Appearance) {
        terminate()
        XCUIDevice.shared.appearance = appearance
        launchArguments = arguments + ["-PRHubAppearance", appearance == .dark ? "dark" : "light"]
        launch()
    }
}

@MainActor
extension XCUIApplication {
    /// Scrolls Settings until `element` can be tapped, then waits for the page to stop: a tap on a page still moving
    /// only stops it.
    func scrollSettings(to element: XCUIElement, up: Bool = true) -> Bool {
        let page = scrollViews["prhub-settings"]
        for _ in 0 ..< 10 where !isClearOfBars(element) {
            if up {
                page.swipeUp(velocity: .slow)
            } else {
                page.swipeDown(velocity: .slow)
            }
        }
        waitForStill(element)
        return isClearOfBars(element)
    }

    /// Scrolls the page whichever way `element` lies until it is out from under the bars, then waits for it to stop.
    /// Down the page while it is not drawn yet or sits below the bars; back up while it is above them. A PR's page puts
    /// its summary over Review changes (2026-11-14): in the largest text the button is several screens down, and the
    /// lazy page has not made it yet.
    func reveal(_ element: XCUIElement) -> Bool {
        // The review alerts offer comes up over the PRs when the app decides, and takes the tap meant for the page
        // (an iPad on CI, 2026-11-14): Not now, as someone reading would.
        let notNow = alerts.buttons["Not now"]
        if notNow.exists {
            notNow.tap()
        }
        for _ in 0 ..< 15 where !isTappable(element) {
            if notNow.exists {
                notNow.tap()
            }
            let top = bars.top
            if element.exists, case let place = element.frame, place.maxY > 0, place.midY < top {
                swipeDown(velocity: .slow)
            } else {
                swipeUp(velocity: .slow)
            }
        }
        waitForStill(element)
        return isTappable(element)
    }

    func waitForStill(_ element: XCUIElement) {
        var frame = element.frame
        for _ in 0 ..< 10 {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
            if element.frame == frame {
                break
            }
            frame = element.frame
        }
    }

    /// Its middle, where a tap lands, on screen and out from under the bars: a row taller than a swipe's step (Files
    /// changed in the largest text) is never whole between them, and `reveal` went back and forth past it.
    private func isTappable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else {
            return false
        }
        let bars = bars, place = element.frame
        return place.midY > bars.top && place.midY < bars.bottom
    }

    /// On screen and out from under the nav bar and the tab bar, which take a tap meant for what scrolls under them.
    func isClearOfBars(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else {
            return false
        }
        let bars = bars, place = element.frame
        return place.minY >= bars.top && place.maxY <= bars.bottom
    }

    /// The band between the nav bar's foot and the tab bar's top, each bar looked up once. A regular width shows its
    /// tabs at the top, outside any tab bar (`PRHubPlace`), so it has no tab bar to look for: looking for one that is
    /// not there reads the whole screen, and in the largest text over a long diff each look took up to a minute until
    /// XCTest gave up (CI's iPad, 2026-11-17).
    private var bars: (top: CGFloat, bottom: CGFloat) {
        let navigationBar = navigationBars.firstMatch
        let top = navigationBar.exists ? navigationBar.frame.maxY : 0
        guard windows.firstMatch.horizontalSizeClass != .regular else {
            return (top, frame.maxY)
        }
        let tabBar = tabBars.firstMatch
        return (top, tabBar.exists ? tabBar.frame.minY : frame.maxY)
    }
}
