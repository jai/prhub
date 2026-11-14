import PRKit
import PRKitDesign
import SwiftUI

/// The Mac's window: the PRs, at the app's text size (`Font.app`), drawn afresh whenever View → Make Text Bigger or
/// Smaller changes it. Whatever asks for the phone's Settings tab (`prhub://settings`) opens the Settings window.
struct PRHubMacWindow: View {
    let environment: PRHubEnvironment
    @AppStorage(MacTextSize.key) private var textScale = MacTextSize.standard
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        PRKitRoot(environment.prs)
            .font(.appBody)
            .id(textScale)
            .frame(minWidth: 720, minHeight: 480)
            .onChange(of: environment.navigation.selectedTab, initial: true) { _, tab in
                guard tab == .settings else {
                    return
                }
                environment.navigation.selectedTab = .prs
                openSettings()
            }
            // No push reaches the Mac, so it keeps itself fresh while the window is open.
            .task {
                while !environment.isSample, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(120))
                    await environment.prs.refresh(.foreground)
                }
            }
    }
}
