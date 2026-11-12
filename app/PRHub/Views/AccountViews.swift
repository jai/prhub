import SwiftUI

/// Settings' AI block on the hosted Worker: the person's own Anthropic key (`PUT` and `DELETE /account/anthropic-key`).
/// The key is pasted or typed into a secure field, sent once, and never shown again: the Worker answers only whether
/// one is set (`account.anthropic_key`). Which AI features it turns on is the config's to say.
struct AnthropicKeySection: View {
    let connection: WorkerConnection
    @State private var key = ""
    @State private var isWorking = false
    @State private var failure: AccountActionError?
    @FocusState private var isFocused: Bool

    private var hasKey: Bool { connection.config?.account?.anthropicKey == true }

    var body: some View {
        PRPageBlock(
            "AI",
            note: hasKey
                ? "Key lines, Rewrite and Ask AI run on your key, billed to your Anthropic account. PRHub never "
                    + "shows the key again."
                : "Key lines, Rewrite and Ask AI run on your own Anthropic key, billed to your Anthropic account. "
                    + "Make one at console.anthropic.com. PRHub keeps it encrypted and never shows it again."
        ) {
            if hasKey {
                PRValueLine("Anthropic key") {
                    Label("Key set", systemImage: AppIcon.ok.symbol)
                        .labelStyle(.iconText)
                        .foregroundStyle(Color.toneGood)
                }
                .accessibilityIdentifier("prhub-anthropic-key-set")
                .transition(.fold)
                if let config = connection.config {
                    PRValueLine("AI", value: PRHubSettingsView.aiWords(config))
                        .accessibilityIdentifier("prhub-ai-features")
                        .transition(.fold)
                }
                Button("Remove key", systemImage: AppIcon.delete.symbol, role: .destructive) {
                    run { try await connection.removeAnthropicKey() }
                }
                .labelStyle(.iconText)
                .buttonStyle(PRButtonStyle(.secondary))
                .tint(Color.toneBad)
                .disabled(isWorking)
                .accessibilityIdentifier("prhub-anthropic-key-remove")
                .transition(.fold)
            } else {
                SecureField("Paste your Anthropic API key", text: $key)
                    .font(.appFootnote.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .focused($isFocused)
                    .prField(isFocused: isFocused)
                    .accessibilityIdentifier("prhub-anthropic-key-field")
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
                            Text("Save key").opacity(isWorking ? 0 : 1)
                            if isWorking {
                                ProgressView().tint(Color.onAccent)
                            }
                        }
                    }
                    .buttonStyle(PRButtonStyle(.primary))
                    .disabled(isWorking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("prhub-anthropic-key-save")
                }
                .transition(.fold)
            }
            if let failure {
                ProblemLine(message: failure.message)
                    .accessibilityIdentifier("prhub-anthropic-key-error")
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
            try await connection.setAnthropicKey(typed)
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
        .background(Color.groundCard)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDeleting)
    }

    private static let deleted = [
        "Your sign-in and GitHub tokens",
        "Your PR list, diffs and AI answers",
        "Your Anthropic key",
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
