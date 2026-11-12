import PRKit
import PRKitDesign
import SwiftUI

/// PRHub → Settings… (⌘,): the phone's Settings tab as a window of its own, over the samples while they show.
struct PRHubMacSettings: View {
    let environment: PRHubEnvironment
    @AppStorage(MacTextSize.key) private var textScale = MacTextSize.standard

    private var shown: PRHubEnvironment {
        environment.sample ?? environment
    }

    var body: some View {
        PRHubSettingsView(
            environment: shown,
            endSample: environment.sample == nil ? nil : { environment.endSample() }
        )
        .prKitEnvironment(shown.prs)
        .font(.appBody)
        .id(textScale)
        .frame(width: 520, height: 640)
    }
}
