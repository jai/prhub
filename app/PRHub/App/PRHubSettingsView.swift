import SwiftUI
#if os(iOS)
import UIKit
#endif

/// PRHub's one other screen. Signed in with GitHub: the account, the GitHub App's installs, the person's own
/// Anthropic key, Sign out and Delete Account. Paired with a pr-worker: that Worker, what it serves
/// (`GET /device/config`) and Disconnect. Over the samples: what they are, and the way back to onboarding. The version
/// always.
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
            Form {
                if let endSample {
                    samplesSection(endSample)
                } else if connection.isHosted {
                    accountSections
                } else {
                    workerSections
                }
                Section("About") {
                    LabeledContent("Version", value: AppIdentity.appVersion())
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $confirmsDelete) {
                DeleteAccountSheet(login: connection.config?.account?.login) {
                    try await environment.deleteAccount()
                }
            }
        }
    }

    private func samplesSection(_ endSample: @escaping () -> Void) -> some View {
        Section {
            Text("You're looking at sample PRs in made-up repos. Nothing you do here reaches GitHub.")
                .accessibilityIdentifier("prhub-samples-explained")
            Button(
                connection.build.signInWithGitHub ? "Sign in with GitHub" : "Connect your own Worker",
                systemImage: connection.build.signInWithGitHub ? "person.crop.circle" : "link"
            ) { endSample() }
                .accessibilityIdentifier("prhub-connect-own-worker")
        } header: {
            Text("Sample PRs")
        } footer: {
            Text(connection.build.signInWithGitHub
                 ? "Sign in with GitHub to see your own PRs."
                 : "PRHub shows your own PRs through a pr-worker that you deploy to your Cloudflare account. "
                    + "The guide is at github.com/jai/prhub.")
        }
    }

    // MARK: - Signed in with GitHub

    @ViewBuilder private var accountSections: some View {
        let account = connection.config?.account
        Section("GitHub") {
            LabeledContent("Signed in as", value: account?.login ?? connection.config?.login ?? "…")
                .accessibilityIdentifier("prhub-account-login")
            if let config = connection.config, config.isOn(.push) {
                reviewAlertsRow
            }
        }
        Section {
            Link(destination: PRHubBuild.appInstallURL) {
                Label("Install PRHub App on your orgs", systemImage: "building.2")
            }
            .accessibilityIdentifier("prhub-install-app")
        } header: {
            Text("Organizations")
        } footer: {
            // TODO: list the orgs without the App once `GET /device/config` names them (docs/plans/github-app.md).
            Text("PRHub sees PRs only where the PRHub GitHub App is installed. An org owner installs it; a member "
                 + "can ask for it on the same page.")
        }
        AnthropicKeySection(connection: connection)
        Section {
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                signingOut = true
                Task {
                    await environment.signOut()
                    signingOut = false
                }
            }
            .disabled(signingOut)
            .accessibilityIdentifier("prhub-sign-out")
            Button("Delete account", systemImage: AppIcon.delete.rawValue, role: .destructive) {
                confirmsDelete = true
            }
            .accessibilityIdentifier("prhub-delete-account")
        } footer: {
            Text("Sign out forgets your PRs on this phone. Delete account also deletes everything PRHub keeps for "
                 + "you and removes its access on GitHub.")
        }
    }

    @ViewBuilder private var workerSections: some View {
        Section("pr-worker") {
            LabeledContent("Worker", value: connection.host ?? "Not connected")
                .accessibilityIdentifier("prhub-worker-host")
            LabeledContent("GitHub login", value: connection.config?.login ?? "Not read yet")
            if let config = connection.config {
                LabeledContent(
                    "Push", value: config.isOn(.push) ? "On, through the relay" : "Off: syncs when opened"
                )
                LabeledContent(
                    "Updates",
                    value: config.isOn(.webhooks) ? "Within seconds (webhooks)" : "About once a minute"
                )
                LabeledContent("AI", value: Self.aiWords(config))
                    .accessibilityIdentifier("prhub-ai-features")
                if config.isOn(.push) {
                    reviewAlertsRow
                }
            }
        }
        Section {
            Button("Disconnect from this pr-worker", role: .destructive) { confirmsDisconnect = true }
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
    }

    /// Whether a review request shows as a notification, and the way to turn that on.
    @ViewBuilder private var reviewAlertsRow: some View {
        let permission = environment.alertPermission
        switch permission.status {
        case .allowed:
            LabeledContent("Review alerts", value: "On")
        case .notAsked:
            Button("Turn on review alerts", systemImage: "bell.badge") { Task { await permission.ask() } }
                .accessibilityIdentifier("prhub-turn-on-alerts")
        case .denied:
            #if os(iOS)
            Button("Review alerts are off in iOS Settings", systemImage: "bell.slash") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #else
            LabeledContent("Review alerts", value: "Off in System Settings")
            #endif
        case .unknown:
            LabeledContent("Review alerts", value: "…")
                .task { await permission.reload() }
        }
    }

    /// The model-backed features this Worker has a key for, or that it has none.
    static func aiWords(_ config: DeviceConfig) -> String {
        let names = [DeviceFeature.askAI, .keyLines, .rewrite].filter(config.isOn).map(\.title)
        return names.isEmpty ? "Off: no Anthropic key on the Worker" : names.joined(separator: ", ")
    }
}
