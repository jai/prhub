import PRHubCore
import PRKit
import SwiftUI

@main
struct PRHubApp: App {
    #if os(iOS)
        /// The phone's launch wiring: pushes and the notification delegate. The Mac gets no pushes.
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    /// A fixture launch (`-PRHubPaired`, `-PRHubHosted`, `-PRHubFirstRun`): PRHub over the sample PRs and a fake
    /// Worker, for the UI tests, the screenshot captures and Tester Army (`PRHubFixtureEnvironment`). Debug only.
    @MainActor private static let screenshotEnvironment: PRHubEnvironment? = {
        #if DEBUG
            PRHubFixtureLaunch.environment()
        #else
            nil
        #endif
    }()

    /// `-PRHubAppearance dark` or `light`: the UI tests' pictures in the look they name. Debug only.
    private static let fixtureColorScheme: ColorScheme? = {
        #if DEBUG
            PRHubFixtureLaunch.colorScheme()
        #else
            nil
        #endif
    }()

    var body: some Scene {
        WindowGroup {
            Self.windowContent { PRHubRootView(environment: $0) }
                // DESIGN.md's icon style, for every symbol in the app.
                .symbolVariant(DesignTokens.iconVariant)
                .preferredColorScheme(Self.fixtureColorScheme)
            #if os(macOS)
                // A link from outside (a PR handoff, a setup link, `prhub://settings`) goes to the PRs window that is
                // open. Without this the Mac opened one more PRs window for every link.
                .handlesExternalEvents(preferring: MacExternalEvents.all, allowing: MacExternalEvents.all)
            #endif
        }
        #if os(macOS)
        // With no PRs window open, a link opens one: this scene, not Feedback or Settings.
        .handlesExternalEvents(matching: MacExternalEvents.all)
        .defaultSize(width: 1200, height: 800)
        .commands { MacTextSizeCommands() }
        #endif
        #if os(macOS)
            Window("Feedback", id: PRHubMacFeedback.windowID) {
                Self.windowContent { environment in
                    PRHubMacFeedback(environment: environment)
                        .prKitOfflineBanner(environment.prs)
                }
                .handlesExternalEvents(preferring: MacExternalEvents.none, allowing: MacExternalEvents.none)
                .symbolVariant(DesignTokens.iconVariant)
                .preferredColorScheme(Self.fixtureColorScheme)
            }
            // Room for the list and a chat beside it.
            .defaultSize(width: 920, height: 720)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Settings {
                Self.windowContent { PRHubMacSettings(environment: $0) }
                    .handlesExternalEvents(preferring: MacExternalEvents.none, allowing: MacExternalEvents.none)
                    .symbolVariant(DesignTokens.iconVariant)
                    .preferredColorScheme(Self.fixtureColorScheme)
            }
        #endif
    }

    #if os(macOS)
        /// Which links from outside a Mac window takes: the PRs window all of them, Feedback and Settings none, as
        /// only the PRs window's `onOpenURL` knows what to do with one.
        private enum MacExternalEvents {
            static let all: Set<String> = ["*"]
            static let none: Set<String> = []
        }
    #endif

    /// Every window's content: on a fixture launch the fixture's environment and storage, and links out of the app
    /// stay in it; the app's own links still come back through `onOpenURL`.
    @MainActor @ViewBuilder private static func windowContent<Content: View>(
        @ViewBuilder _ content: (PRHubEnvironment) -> Content
    ) -> some View {
        if AppIdentity.isRunningTests {
            // The unit tests are hosted in this app; they get an empty window instead of the live UI.
            EmptyView()
        } else {
            #if DEBUG
                if let environment = screenshotEnvironment {
                    content(environment)
                        .defaultAppStorage(PRHubUITestResources.current?.defaults ?? .standard)
                        .environment(\.openURL, OpenURLAction { url in
                            url.scheme == PRHubBuild.settingsURL.scheme ? .systemAction : .handled
                        })
                } else {
                    content(.shared)
                }
            #else
                content(.shared)
            #endif
        }
    }
}
