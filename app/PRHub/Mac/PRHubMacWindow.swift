import FeatureKit
import PRHubCore
import PRKit
import PRKitDesign
import SwiftUI

/// The Mac's window: the PRs, at the app's text size (`Font.app`), drawn afresh whenever View → Make Text Bigger or
/// Smaller changes it. Whatever asks for the phone's Settings tab (`prhub://settings`) opens the Settings window, and
/// whatever asks for its Feedback tab opens the Feedback window. Feedback has a button in the toolbar, where the Worker
/// serves it, as the phone has its tab (Jai, 2026-11-24: "Mac version doesn't have a feedback tab?"; the Window menu's
/// item alone was not found). The button carries the count of feedback chats with a question not answered yet, as the
/// phone's tab carries its badge.
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
                    let waiting = environment.feedback.needsAttentionCount
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            openWindow(id: PRHubMacFeedback.windowID)
                        } label: {
                            Label {
                                HStack(spacing: Space.xs) {
                                    Text("Feedback")
                                    // A Mac toolbar item takes no badge of the system's: the count sits in the label.
                                    if waiting > 0 {
                                        MacFeedbackCount(count: waiting)
                                    }
                                }
                            } icon: {
                                Image(systemName: AppIcon.conversation.symbol)
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Send feedback and follow your requests (⇧⌘F)")
                        .accessibilityLabel("Feedback")
                        .accessibilityValue(waiting > 0 ? "\(waiting) need you" : "")
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

/// How many feedback chats have a question not answered yet, as a badge beside the toolbar button's title.
private struct MacFeedbackCount: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.appCaption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, Space.xs)
            .background(Color.toneBad, in: .capsule)
            .accessibilityHidden(true)
    }
}
