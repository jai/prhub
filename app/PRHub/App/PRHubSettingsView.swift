import SwiftUI
#if os(iOS)
import UIKit
#endif

/// PRHub's one other screen. Signed in with GitHub: the account, where the GitHub App is installed, the person's own
/// Anthropic key, Sign out and Delete Account. Paired with a pr-worker: that Worker, what it serves
/// (`GET /device/config`) and Disconnect. Over the samples: what they are, and the way back to onboarding. The diff's
/// font and the version always.
struct PRHubSettingsView: View {
    let environment: PRHubEnvironment
    /// Back from the samples to onboarding; nil over a paired Worker.
    var endSample: (() -> Void)?
    @State private var confirmsDisconnect = false
    @State private var confirmsDelete = false
    @State private var signingOut = false

    private var connection: WorkerConnection { environment.connection }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if let endSample {
                        samplesBlock(endSample)
                    } else if connection.isHosted {
                        accountBlocks
                    } else if connection.isPaired {
                        // Before a way in is chosen, which only the Mac's Settings window can show, neither.
                        workerBlocks
                    }
                    DiffFontSection()
                        .recordsDiffFontChanges(environment.usage)
                    UsageSharingSection(usage: environment.usage)
                    PRPageBlock("About") {
                        PRValueLine("Version", value: AppIdentity.appVersion())
                    }
                }
                .padding(.bottom, Space.xl)
                .animation(AppMotion.fold, value: connection.config)
                .animation(AppMotion.fold, value: environment.alertPermission.status)
            }
            .accessibilityIdentifier("prhub-settings")
            .background(Color.groundPage)
            .readableContentWidth()
            .navigationTitle("Settings")
            .sheet(isPresented: $confirmsDelete) {
                DeleteAccountSheet(login: connection.config?.account?.login) {
                    try await environment.deleteAccount()
                }
            }
        }
    }

    private func samplesBlock(_ endSample: @escaping () -> Void) -> some View {
        PRPageBlock(
            "Sample PRs",
            note: connection.build.signInWithGitHub
                ? "Sign in with GitHub to see your own PRs."
                : "PRHub shows your own PRs through a pr-worker that you deploy to your Cloudflare account. "
                    + "The guide is at github.com/jai/prhub."
        ) {
            Text("You're looking at sample PRs in made-up repos. Nothing you do here reaches GitHub.")
                .font(.appFootnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("prhub-samples-explained")
            Button(
                connection.build.signInWithGitHub ? "Sign in with GitHub" : "Connect your own Worker",
                systemImage: (connection.build.signInWithGitHub ? AppIcon.signIn : AppIcon.ownWorker).symbol
            ) { endSample() }
                .labelStyle(.iconText)
                .buttonStyle(PRButtonStyle(.primary))
                .accessibilityIdentifier("prhub-connect-own-worker")
        }
    }

    // MARK: - Signed in with GitHub

    /// GitHub's install and installation pages open in the browser as usual; coming back reads the config fresh.
    private var leavingForGitHub: OpenURLAction {
        OpenURLAction { [connection] url in
            connection.leavesForGitHub(url)
            return .systemAction
        }
    }

    @ViewBuilder private var accountBlocks: some View {
        let account = connection.config?.account
        PRPageBlock("GitHub") {
            PRValueLine("Signed in as", value: account?.login ?? connection.config?.login ?? "…")
                .accessibilityIdentifier("prhub-account-login")
            if let config = connection.config, config.isOn(.push), AppIdentity.receivesPushes {
                reviewAlertsLine
            }
        }
        if connection.config?.installations != nil || connection.isCheckingInstallations {
            GitHubAccessBlock(
                appName: "PRHub", installations: connection.config?.installations ?? [],
                installURL: PRHubBuild.appInstallURL, isChecking: connection.isCheckingInstallations
            )
            .environment(\.openURL, leavingForGitHub)
        } else {
            PRPageBlock(
                "GitHub access",
                note: "PRHub sees PRs only where the PRHub GitHub App is installed. An org owner installs it; a member "
                    + "can ask for it on the same page."
            ) {
                Link(destination: PRHubBuild.appInstallURL) {
                    Label("Install PRHub App on your orgs", systemImage: AppIcon.installApp.symbol)
                        .labelStyle(.iconText)
                }
                .buttonStyle(PRButtonStyle(.secondary))
                .accessibilityIdentifier("prhub-install-app")
            }
            .environment(\.openURL, leavingForGitHub)
        }
        AnthropicKeySection(connection: connection)
        PRPageBlock(
            "Account",
            note: "Sign out forgets your PRs on this \(AppIdentity.deviceName). Delete account also deletes everything "
                + "PRHub keeps for you and removes its access on GitHub."
        ) {
            Button("Sign out", systemImage: AppIcon.signOut.symbol) {
                signingOut = true
                Task {
                    await environment.signOut()
                    signingOut = false
                }
            }
            .labelStyle(.iconText)
            .buttonStyle(PRButtonStyle(.secondary))
            .disabled(signingOut)
            .accessibilityIdentifier("prhub-sign-out")
            Button("Delete account", systemImage: AppIcon.delete.symbol, role: .destructive) {
                confirmsDelete = true
            }
            .labelStyle(.iconText)
            .buttonStyle(PRButtonStyle(.secondary))
            .tint(Color.toneBad)
            .accessibilityIdentifier("prhub-delete-account")
        }
    }

    @ViewBuilder private var workerBlocks: some View {
        PRPageBlock("pr-worker") {
            PRValueLine("Worker", value: connection.host ?? "Not connected")
                .accessibilityIdentifier("prhub-worker-host")
            PRValueLine("GitHub login", value: connection.config?.login ?? "Not read yet")
            if let config = connection.config {
                PRValueLine("Push", value: config.isOn(.push) ? "On, through the relay" : "Off: syncs when opened")
                PRValueLine(
                    "Updates", value: config.isOn(.webhooks) ? "Within seconds (webhooks)" : "About once a minute"
                )
                PRValueLine("AI", value: Self.aiWords(config))
                    .accessibilityIdentifier("prhub-ai-features")
                if config.isOn(.push), AppIdentity.receivesPushes {
                    reviewAlertsLine
                }
            }
        }
        PRPageBlock {
            Button("Disconnect from this pr-worker", role: .destructive) { confirmsDisconnect = true }
                .buttonStyle(PRButtonStyle(.secondary))
                .tint(Color.toneBad)
                .accessibilityIdentifier("disconnectWorker")
                .confirmationDialog(
                    "Disconnect from \(connection.host ?? "this pr-worker")?",
                    isPresented: $confirmsDisconnect, titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) { Task { await environment.disconnect() } }
                } message: {
                    Text("PRHub forgets this Worker and its PRs. To connect again, run npm run pair on your "
                         + "pr-worker for a new setup link.")
                }
        }
        .padding(.top, Space.lg)
    }

    /// Whether a review request shows as a notification, and the way to turn that on.
    @ViewBuilder private var reviewAlertsLine: some View {
        let permission = environment.alertPermission
        switch permission.status {
        case .allowed:
            PRValueLine("Review alerts", value: "On")
        case .notAsked:
            Button("Turn on review alerts", systemImage: AppIcon.alertsTurnOn.symbol) {
                Task { await permission.ask() }
            }
            .labelStyle(.iconText)
            .buttonStyle(PRButtonStyle(.secondary))
            .accessibilityIdentifier("prhub-turn-on-alerts")
        case .denied:
            #if os(iOS)
            Button("Review alerts are off in iOS Settings", systemImage: AppIcon.alertsOff.symbol) {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .labelStyle(.iconText)
            .buttonStyle(PRButtonStyle(.secondary))
            #else
            PRValueLine("Review alerts", value: "Off in System Settings")
            #endif
        case .unknown:
            PRValueLine("Review alerts", value: "…")
                .task { await permission.reload() }
        }
    }

    /// The model-backed features this Worker has a key for, or that it has none.
    static func aiWords(_ config: DeviceConfig) -> String {
        let names = [DeviceFeature.askAI, .keyLines, .rewrite].filter(config.isOn).map(\.title)
        return names.isEmpty ? "Off: no Anthropic key on the Worker" : names.joined(separator: ", ")
    }
}
