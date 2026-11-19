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
    /// Worker, for the UI tests, the screenshot captures and Tester Army (`PRHubScreenshotEnvironment`). Debug only.
    @MainActor private static let screenshotEnvironment: PRHubEnvironment? = {
        #if DEBUG
            PRHubScreenshots.environment()
        #else
            nil
        #endif
    }()

    /// `-PRHubAppearance dark` or `light`: the UI tests' pictures in the look they name. Debug only.
    private static let screenshotColorScheme: ColorScheme? = {
        #if DEBUG
            PRHubScreenshots.colorScheme()
        #else
            nil
        #endif
    }()

    #if os(macOS) && DEBUG
        init() {
            PRHubMacSnapshot.openWindowIfNoneOpened {
                Self.windowContent { PRHubRootView(environment: $0) }
                    .symbolVariant(DesignTokens.iconVariant)
                    .task { await PRHubMacSnapshot.runIfAsked() }
            }
        }
    #endif

    var body: some Scene {
        WindowGroup {
            Self.windowContent { PRHubRootView(environment: $0) }
                // DESIGN.md's icon style, for every symbol in the app.
                .symbolVariant(DesignTokens.iconVariant)
                .preferredColorScheme(Self.screenshotColorScheme)
            #if os(macOS) && DEBUG
                .task { await PRHubMacSnapshot.runIfAsked() }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .commands { MacTextSizeCommands() }
        #endif
        #if os(macOS)
            Window("Feedback", id: PRHubMacFeedback.windowID) {
                Self.windowContent { environment in
                    PRHubMacFeedback(environment: environment)
                        .prKitOfflineBanner(environment.prs)
                }
                .symbolVariant(DesignTokens.iconVariant)
                .preferredColorScheme(Self.screenshotColorScheme)
            }
            .defaultSize(width: 560, height: 720)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Settings {
                Self.windowContent { PRHubMacSettings(environment: $0) }
                    .symbolVariant(DesignTokens.iconVariant)
                    .preferredColorScheme(Self.screenshotColorScheme)
            }
        #endif
    }

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
