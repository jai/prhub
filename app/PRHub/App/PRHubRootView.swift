import SwiftUI

/// PRHub's window: the onboarding screen until a pr-worker is paired, then the PRs and Settings. "Try with sample PRs"
/// shows the same tabs over the samples, until Settings' "Connect your own Worker". A setup link opened from anywhere
/// arrives here.
struct PRHubRootView: View {
    let environment: PRHubEnvironment
    @Environment(\.scenePhase) private var scenePhase

    private enum Screen {
        case onboarding, samples, tabs
    }

    private var screen: Screen {
        if environment.sample != nil {
            return .samples
        }
        return environment.connection.showsOnboarding ? .onboarding : .tabs
    }

    var body: some View {
        let connection = environment.connection
        Group {
            switch screen {
            case .onboarding:
                OnboardingView(connection: connection, trySamples: { environment.startSample() })
                    .transition(.opacity)
            case .samples:
                if let sample = environment.sample {
                    PRHubTabs(environment: sample, endSample: { environment.endSample() })
                        .transition(.opacity)
                }
            case .tabs:
                PRHubTabs(environment: environment, endSample: nil)
                    .transition(.opacity)
            }
        }
        .animation(AppMotion.swap, value: screen)
        .sensoryFeedback(.success, trigger: connection.showsOnboarding) { wasShowing, isShowing in
            wasShowing && !isShowing && connection.isPaired
        }
        .onOpenURL { url in
            // A setup link ends the samples: it is the user's own Worker.
            if environment.sample != nil {
                environment.endSample()
            }
            connection.open(url)
        }
        .alert(
            "Already connected",
            isPresented: Binding(
                get: { connection.ignoredLinkHost != nil },
                set: { if !$0 { connection.ignoredLinkHost = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This phone is connected to \(connection.ignoredLinkHost ?? "a pr-worker"). To use another one, tap "
                 + "Disconnect in Settings first.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await environment.becameActive() }
            }
        }
        // Just paired: the first list, and the push token if the Worker pushes.
        .onChange(of: connection.showsOnboarding) { _, isShowing in
            if !isShowing {
                Task {
                    await environment.prs.refresh(.foreground)
                    await environment.offerAlertsIfDue()
                }
            }
        }
    }
}

/// The PRs and Settings, over a paired Worker or over the samples. `endSample` is Settings' way back from the samples.
private struct PRHubTabs: View {
    let environment: PRHubEnvironment
    let endSample: (() -> Void)?

    var body: some View {
        @Bindable var navigation = environment.navigation
        TabView(selection: $navigation.selectedTab) {
            Tab("PRs", systemImage: "arrow.triangle.pull", value: PRHubTab.prs) {
                PRKitRoot(environment.prs)
            }
            Tab("Settings", systemImage: "gearshape", value: PRHubTab.settings) {
                PRHubSettingsView(environment: environment, endSample: endSample)
            }
        }
        .readableContentWidth()
        .prKitEnvironment(environment.prs)
        .alertsOffer(environment.alertPermission)
        .environment(\.loadsAuthorAvatars, !environment.isSample)
    }
}

extension View {
    /// The one offer to turn on review alerts, over the PRs, before the system asks.
    fileprivate func alertsOffer(_ permission: PRHubAlertPermission) -> some View {
        @Bindable var permission = permission
        return alert("Get review alerts?", isPresented: $permission.isOffering) {
            Button("Not now", role: .cancel) { permission.decline() }
            Button("Turn on") { Task { await permission.ask() } }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("PRHub tells you when someone asks for your review, and a tap opens the PR. You can change this in "
                 + "Settings.")
        }
    }
}
