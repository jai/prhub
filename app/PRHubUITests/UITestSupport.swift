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
