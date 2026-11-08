import SwiftUI

/// PRHub's window: onboarding until the phone is signed in with GitHub or paired with a pr-worker, then the PRs and
/// Settings, or Sign in again once the hosted Worker says GitHub signed the person out. "Try with sample PRs" shows the
/// same tabs over the samples, until Settings' way back. A setup link opened from anywhere arrives here.
struct PRHubRootView: View {
    let environment: PRHubEnvironment
    @Environment(\.scenePhase) private var scenePhase

    private enum Screen {
        case onboarding, samples, signedOut, tabs
    }

    private var screen: Screen {
        if environment.sample != nil {
            return .samples
        }
        if environment.connection.showsOnboarding {
            return .onboarding
        }
        return environment.connection.needsSignInAgain ? .signedOut : .tabs
    }

    var body: some View {
        let connection = environment.connection
        Group {
            switch screen {
            case .onboarding:
                OnboardingView(
                    connection: connection,
                    signIn: { Task { await environment.signIn() } },
                    trySamples: connection.build.samples ? { environment.startSample() } : nil
                )
                .transition(.opacity)
            case .signedOut:
                SignedOutView(environment: environment)
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
        .onChange(of: connection.needsSignInAgain) { wasSignedOut, isSignedOut in
            // Signed in again: the list, as after a first sign-in.
            if wasSignedOut, !isSignedOut, connection.isPaired {
                Task { await environment.prs.refresh(.foreground) }
            }
        }
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
                    .compactWidthForUITests()
            }
            .accessibilityIdentifier(PRHubTab.prs.identifier)
            Tab("Settings", systemImage: AppIcon.settings.symbol, value: PRHubTab.settings) {
                PRHubSettingsView(environment: environment, endSample: endSample)
            }
            .accessibilityIdentifier(PRHubTab.settings.identifier)
        }
        .background(TabBarIdentifiers(identifiers: [PRHubTab.prs, .settings].map(\.identifier)))
        .readableContentWidth()
        .prKitEnvironment(environment.prs)
        .alertsOffer(environment.alertPermission)
        .environment(\.loadsAuthorAvatars, !environment.isSample)
    }
}

extension View {
    /// A Debug run's `-PRHubCompactWidth`: a narrow Split View's size class, which a UI test can't make with the
    /// window. Set on the window, so the screens a stack pushes have it too.
    fileprivate func compactWidthForUITests() -> some View {
        #if DEBUG
        onAppear {
            guard PRHubScreenshots.forcesCompactWidth else {
                return
            }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.windows.forEach { $0.traitOverrides.horizontalSizeClass = .compact }
            }
        }
        #else
        self
        #endif
    }

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

extension PRHubTab {
    /// The tab's accessibility identifier, which the UI tests reach it by (`PRHubPlace`).
    fileprivate var identifier: String {
        switch self {
        case .prs: "prhub-tab-prs"
        case .settings: "prhub-tab-settings"
        }
    }
}

/// The tabs' accessibility identifiers on a phone's tab bar buttons. `Tab`'s `accessibilityIdentifier` reaches an iPad's
/// tabs at the top but not a phone's tab bar, whose buttons come from the `UITabBarController`'s items, so this sets
/// them on the items, in the tabs' order.
private struct TabBarIdentifiers: UIViewRepresentable {
    let identifiers: [String]

    func makeUIView(context: Context) -> Probe {
        Probe(identifiers: identifiers)
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.apply()
    }

    final class Probe: UIView {
        private let identifiers: [String]

        init(identifiers: [String]) {
            self.identifiers = identifiers
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// After this turn of the run loop: the tab bar controller is not in the window yet when the probe is.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else {
                return
            }
            var controllers = [window.rootViewController].compactMap(\.self)
            while let controller = controllers.popLast() {
                if let tabs = controller as? UITabBarController {
                    for (item, identifier) in zip(tabs.tabBar.items ?? [], identifiers) {
                        item.accessibilityIdentifier = identifier
                    }
                    return
                }
                controllers += controller.children
            }
        }
    }
}
