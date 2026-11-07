import SwiftUI

@main
struct PRHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// `-PRHubPaired` (with `-PRHubNoAI` or `-PRHubSettings`): PRHub over the sample PRs as if paired, for the UI
    /// tests' screenshots. Debug only.
    @MainActor private static let screenshotEnvironment: PRHubEnvironment? = {
        #if DEBUG
        PRHubScreenshots.environment()
        #else
        nil
        #endif
    }()

    var body: some Scene {
        WindowGroup {
            root
                // DESIGN.md's icon style, for every symbol in the app.
                .symbolVariant(DesignTokens.iconVariant)
        }
    }

    @ViewBuilder private var root: some View {
        if AppIdentity.isRunningTests {
            // The unit tests are hosted in this app; they get an empty window instead of the live UI.
            EmptyView()
        } else if let environment = Self.screenshotEnvironment {
            PRHubRootView(environment: environment)
        } else {
            PRHubRootView(environment: .shared)
        }
    }
}
