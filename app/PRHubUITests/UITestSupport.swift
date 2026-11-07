import XCTest

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
