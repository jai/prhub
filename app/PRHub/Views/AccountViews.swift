import SwiftUI

enum AccountKeyProvider: String {
    case anthropic
    case linear

    var title: String {
        self == .linear ? "Linear" : "Anthropic"
    }
}

struct AccountKeySection: View {
    let provider: AccountKeyProvider
    let connection: WorkerConnection
    @State private var key = ""
    @State private var isWorking = false
    @State private var failure: AccountActionError?
    @FocusState private var isFocused: Bool

    private var hasKey: Bool {
        provider == .linear ? connection.config?.account?.linearKey == true
            : connection.config?.account?.anthropicKey == true
    }

    /// Linear said the connected key may only read: Ask can't comment on tickets with it.
    private var isReadOnly: Bool {
        provider == .linear && hasKey && connection.config?.account?.linearCanComment == false
    }

    private var note: String {
        if provider == .linear {
            return hasKey ? "Ticket titles and statuses come from your Linear account, and Ask AI comments on tickets "
                + "as you once you post its card. Disconnect to stop."
                : "Show ticket titles and statuses under your PRs, and let Ask AI comment on tickets once you confirm. "
                + "Create a personal API key in Linear Settings → Security & access, with Read and Write (or Create "
                + "comments) permission for your teams. PRHub keeps it encrypted."
        }
        return "Key lines, Rewrite and Ask AI run on your own Anthropic key, billed to your Anthropic account. "
            + "Make one at console.anthropic.com. PRHub keeps it encrypted and never shows it again."
    }

    var body: some View {
        PRPageBlock(provider == .linear ? "Linear" : "AI", note: note) {
            if hasKey {
                PRValueLine(provider == .linear ? "Linear" : "Anthropic key") {
                    Label(provider == .linear ? "Connected" : "Key set", systemImage: AppIcon.ok.symbol)
                        .labelStyle(.iconText)
                        .foregroundStyle(Color.toneGood)
                }
                .accessibilityIdentifier("prhub-\(provider.rawValue)-key-set")
                .transition(.fold)
                if provider == .anthropic, let config = connection.config {
                    PRValueLine("AI", value: PRHubSettingsView.aiWords(config))
                        .accessibilityIdentifier("prhub-ai-features")
                        .transition(.fold)
                }
                Button(provider == .linear ? "Disconnect Linear" : "Remove key", systemImage: AppIcon.delete.symbol, role: .destructive) {
                    run {
                        if provider == .linear {
                            try await connection.removeLinearKey()
                        } else {
                            try await connection.removeAnthropicKey()
                        }
                    }
                }
                .buttonStyle(PRButtonStyle(.secondary))
                .tint(Color.toneBad)
                .disabled(isWorking)
                .accessibilityIdentifier("prhub-\(provider.rawValue)-key-remove")
                .transition(.fold)
                if isReadOnly {
                    ProblemLine(message: "This key can only read, so Ask AI can't comment on tickets. Paste a key with "
                        + "Write or Create comments permission to replace it.")
                        .accessibilityIdentifier("prhub-linear-read-only")
                        .transition(.fold)
                }
            }
            if !hasKey || isReadOnly {
                SecureField("Paste your \(provider.title) API key", text: $key)
                    .font(.appFootnote.monospaced())
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .focused($isFocused)
                    .prField(isFocused: isFocused)
                    .accessibilityIdentifier("prhub-\(provider.rawValue)-key-field")
                    .transition(.fold)
                HStack(spacing: Space.sm) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else {
                            return
                        }
                        Task { @MainActor in key = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.appFootnote.weight(.semibold))
                    .buttonBorderShape(.roundedRectangle(radius: Radius.sm))
                    Spacer()
                    Button(action: save) {
                        ZStack {
                            Text(provider == .linear ? (hasKey ? "Replace key" : "Connect Linear") : "Save key").opacity(isWorking ? 0 : 1)
                            if isWorking {
                                ProgressView().tint(Color.onAccent)
                            }
                        }
                    }
                    .buttonStyle(PRButtonStyle(.primary))
                    .disabled(isWorking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("prhub-\(provider.rawValue)-key-save")
                }
                .transition(.fold)
            }
            if let failure {
                ProblemLine(message: failure.message)
                    .accessibilityIdentifier("prhub-\(provider.rawValue)-key-error")
                    .transition(.fold)
            }
        }
        .animation(AppMotion.fold, value: hasKey)
        .animation(AppMotion.fold, value: failure)
        .animation(AppMotion.swap, value: isWorking)
        .sensoryFeedback(.success, trigger: hasKey) { wasSet, isSet in !wasSet && isSet }
    }

    private func save() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isWorking else {
            return
        }
        run {
            if provider == .linear {
                try await connection.setLinearKey(typed)
            } else {
                try await connection.setAnthropicKey(typed)
            }
            key = ""
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        isWorking = true
        failure = nil
        Task {
            do {
                try await action()
            } catch {
                failure = error as? AccountActionError ?? .unreachable
            }
            isWorking = false
        }
    }
}

/// Delete Account (App Review 5.1.1(v)): what goes and what stays, then the one destructive button. A real detour, so
/// a sheet; the failure arrives over the button.
struct DeleteAccountSheet: View {
    let login: String?
    let delete: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var failure: AccountActionError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Delete your PRHub account?")
                    .font(.appTitle3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("PRHub deletes everything it keeps for \(login ?? "you"), and removes its access on GitHub:")
                    .font(.appFootnote)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Self.deleted, id: \.self) { line in
                        Label(line, systemImage: AppIcon.remove.symbol)
                            .labelStyle(.iconText)
                            .font(.appFootnote)
                    }
                }
                Text("Your PRs, reviews and comments on GitHub stay. So do installs of the PRHub App on your orgs, "
                    + "until an owner removes them.")
                    .font(.appFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    ProblemLine(message: failure.message)
                        .accessibilityIdentifier("prhub-delete-account-error")
                        .transition(.fold)
                }
                VStack(spacing: Space.sm) {
                    Button(action: confirm) {
                        ZStack {
                            Text("Delete account").opacity(isDeleting ? 0 : 1)
                            if isDeleting {
                                ProgressView().tint(Color.onAccent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xs)
                    }
                    .buttonStyle(PRButtonStyle(.primary))
                    .tint(Color.toneBad)
                    .accessibilityIdentifier("prhub-delete-account-confirm")
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.xs)
                    }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .accessibilityIdentifier("prhub-delete-account-cancel")
                }
                .padding(.top, Space.sm)
                .disabled(isDeleting)
            }
            .padding(Space.lg)
            .animation(AppMotion.fold, value: failure)
        }
        .presentedScrollMargins()
        .background(Color.groundCard)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDeleting)
    }

    private static let deleted = [
        "Your sign-in and GitHub tokens",
        "Your PR list, diffs and AI answers",
        "Your Anthropic and Linear keys",
        "Alerts to your phones",
    ]

    private func confirm() {
        isDeleting = true
        failure = nil
        Task {
            do {
                try await delete()
                dismiss()
            } catch {
                failure = error as? AccountActionError ?? .unreachable
            }
            isDeleting = false
        }
    }
}
