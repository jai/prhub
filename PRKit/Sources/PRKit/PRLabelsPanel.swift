import PRKitCore
import PRKitDesign
import SwiftUI

/// The repo's labels in the panel over a PR's page (`sidePanel`): each a row with its tick, its chip in its colour and
/// what it is for. A tap puts it on the PR or takes it off.
struct PRLabelsPanel: View {
    let session: PRSession
    @State private var filter = ""
    @FocusState private var isFiltering: Bool
    /// A label's colour moves toward readable on the panel's ground, as on the page.
    @Environment(\.colorScheme) private var colorScheme

    private var isOnline: Bool {
        session.model.network.isOnline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("Labels")
                    .font(.appSubheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                // The whole square is the button, as a key line's tick is: with the frame around the button, only
                // the mark itself, a dozen points across, took the tap.
                Button(action: session.closeLabels) {
                    Label("Close", systemImage: AppIcon.close.symbol)
                        .labelStyle(.iconOnly)
                        .font(.appFootnote)
                        .foregroundStyle(.secondary)
                        .frame(width: PRStyle.rowHeight, height: PRStyle.rowHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pr-labels-close")
            }
            .padding(.leading, Space.lg)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.groundCard)
        // The panel sets its own width: a wide screen's readable margins are not for it.
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-labels-list")
        // A read that failed for want of a network is made again when it is back.
        .onChange(of: isOnline) { _, isOnline in
            if isOnline {
                Task { await session.loadLabels(retry: true) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.labelEditing.load {
        case let .ready(repo):
            if repo.labels.isEmpty {
                note("This repo has no labels")
                    .accessibilityIdentifier("pr-labels-empty")
            } else {
                list(repo)
            }
        case .unavailable:
            note("Labels can't be changed here.")
                .accessibilityIdentifier("pr-labels-unavailable")
        case .notRead where !isOnline, .reading where !isOnline, .failed where !isOnline:
            // The read is made again when the network is back; a spinner would say it is coming.
            Label("Labels need a network. They show when it's back.", systemImage: AppIcon.offline.symbol)
                .font(.appCaption)
                .foregroundStyle(Color.toneWaiting)
                .padding(Space.lg)
                .accessibilityIdentifier("pr-labels-offline")
        case .notRead, .reading:
            HStack(spacing: Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the labels…")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.lg)
            .accessibilityIdentifier("pr-labels-reading")
        case let .failed(reason):
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(reason)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .accessibilityIdentifier("pr-labels-failed")
                Button("Try again") { Task { await session.loadLabels(retry: true) } }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .accessibilityIdentifier("pr-labels-retry")
            }
            .padding(Space.lg)
        }
    }

    private func note(_ words: String) -> some View {
        Text(words)
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
    }

    private func list(_ repo: PRRepoLabels) -> some View {
        let shown = repo.labels.filter { $0.matches(filter) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.sm) {
                TextField("Filter labels", text: $filter)
                    .font(.appFootnote)
                    .autocorrectionDisabled()
                    .focused($isFiltering)
                    .prField(isFocused: isFiltering)
                    .accessibilityIdentifier("pr-labels-filter")
                if !repo.canEdit {
                    Text("You can't change labels on this repo.")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pr-labels-read-only")
                }
                if session.model.outbox != nil, !isOnline {
                    Label("You're offline. A change goes to GitHub when you're back online.", systemImage: AppIcon.offline.symbol)
                        .font(.appCaption)
                        .foregroundStyle(Color.toneWaiting)
                        .accessibilityIdentifier("pr-labels-waiting")
                }
                if let problem = session.labelEditing.problem {
                    Text(problem)
                        .font(.appFootnote)
                        .foregroundStyle(Color.toneBad)
                        .accessibilityIdentifier("pr-labels-problem")
                        .transition(.fold)
                }
            }
            .padding(PRStyle.inset)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { label in
                        row(label, canEdit: repo.canEdit)
                        Divider()
                    }
                    if shown.isEmpty {
                        note("No label matches \"\(filter)\".")
                            .accessibilityIdentifier("pr-labels-no-match")
                    }
                }
            }
        }
    }

    /// One label: its tick where a file's viewed mark is in Files, its chip as the page draws it, then what it is for.
    /// A button where labels can be changed; else it is read and not pressed.
    @ViewBuilder
    private func row(_ label: PRRepoLabels.Label, canEdit: Bool) -> some View {
        let isOn = session.hasLabel(label.name)
        let line = HStack(spacing: Space.sm) {
            PRCheckCircle(isOn: isOn)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: Space.xs) {
                StatusChip(
                    text: label.name,
                    tint: GitHubLabelColor(hex: label.color).readable(dark: colorScheme == .dark).color
                )
                if let description = label.description, !description.isEmpty {
                    Text(description)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(minHeight: PRStyle.rowHeight)
        .contentShape(.rect)
        if canEdit {
            Button { session.toggleLabel(label) } label: { line }
                .buttonStyle(.plain)
                .labelRow(label, isOn: isOn)
        } else {
            line
                .accessibilityElement(children: .ignore)
                .labelRow(label, isOn: isOn)
        }
    }
}

private extension View {
    /// What VoiceOver and a UI test read of a label's row: "bug, on" or "bug, off", then what the label is for.
    func labelRow(_ label: PRRepoLabels.Label, isOn: Bool) -> some View {
        accessibilityLabel("\(label.name), \(isOn ? "on" : "off")")
            .accessibilityHint(label.description ?? "")
            .accessibilityIdentifier("pr-label-\(label.name)")
    }
}

private extension PRRepoLabels.Label {
    /// Its name or what it is for holds the words typed, whatever their case. No words match every label.
    func matches(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || name.localizedCaseInsensitiveContains(words)
            || description?.localizedCaseInsensitiveContains(words) == true
    }
}
