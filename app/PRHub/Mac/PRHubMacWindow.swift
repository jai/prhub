import PRHubCore
import PRKit
import PRKitDesign
import SwiftUI

/// The Mac's window: the PRs, at the app's text size (`Font.app`), drawn afresh whenever View → Make Text Bigger or
/// Smaller changes it. Whatever asks for the phone's Settings tab (`prhub://settings`) opens the Settings window, and
/// whatever asks for its Feedback tab opens the Feedback window. Feedback has a button in the toolbar, where the Worker
/// serves it, as the phone has its tab (Jai, 2026-11-24: "Mac version doesn't have a feedback tab?"; the Window menu's
/// item alone was not found).
struct PRHubMacWindow: View {
    let environment: PRHubEnvironment
    @AppStorage(MacTextSize.key) private var textScale = MacTextSize.standard
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// How often an open window reads the PRs again by itself.
    static let refreshInterval: Duration = .seconds(300)

    var body: some View {
        PRKitRoot(environment.prs)
            .font(.appBody)
            .id(textScale)
            .frame(minWidth: 720, minHeight: 480)
            .toolbar {
                if environment.connection.config?.isOn(.feedback) == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Feedback", systemImage: AppIcon.conversation.symbol) {
                            openWindow(id: PRHubMacFeedback.windowID)
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Send feedback and follow your requests (⇧⌘F)")
                        .accessibilityIdentifier("prhub-mac-feedback")
                    }
                }
            }
            .onChange(of: environment.navigation.selectedTab, initial: true) { _, tab in
                guard tab != .prs else {
                    return
                }
                environment.navigation.selectedTab = .prs
                if tab == .settings {
                    openSettings()
                } else {
                    openWindow(id: PRHubMacFeedback.windowID)
                }
            }
            // No push reaches the Mac, so it keeps itself fresh while the window is open.
            .task {
                while !environment.isSample, !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    await environment.prs.refresh(.foreground)
                }
            }
    }
}
