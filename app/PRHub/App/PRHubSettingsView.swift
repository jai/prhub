import SwiftUI
#if os(iOS)
import UIKit
#endif

/// PRHub's one other screen: the pr-worker it is paired with, what that Worker serves (`GET /device/config`), the
/// version, and Disconnect. Over the samples: what they are, and the way to connect a Worker of one's own.
struct PRHubSettingsView: View {
    let environment: PRHubEnvironment
    /// Back from the samples to onboarding; nil over a paired Worker.
    var endSample: (() -> Void)?
    @State private var confirmsDisconnect = false

    private var connection: WorkerConnection { environment.connection }

    var body: some View {
        NavigationStack {
            Form {
                if let endSample {
                    samplesSection(endSample)
                } else {
                    workerSections
                }
                Section("About") {
                    LabeledContent("Version", value: AppIdentity.appVersion())
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func samplesSection(_ endSample: @escaping () -> Void) -> some View {
        Section {
            Text("You're looking at sample PRs in made-up repos. Nothing you do here reaches GitHub.")
                .accessibilityIdentifier("prhub-samples-explained")
            Button("Connect your own Worker", systemImage: "link") { endSample() }
                .accessibilityIdentifier("prhub-connect-own-worker")
        } header: {
            Text("Sample PRs")
        } footer: {
            Text("PRHub shows your own PRs through a pr-worker that you deploy to your Cloudflare account. "
                 + "The guide is at github.com/jai/prhub.")
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
