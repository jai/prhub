import PRKitCore
import PRKitDesign
import SwiftUI

/// Checks, review and merge at a glance; the checks open into a list, and a failing one opens the list by itself.
struct PRStatusCard: View {
    let session: PRSession
    let detail: PullRequestDetail
    let folds: FoldSet
    @State private var isConfirmingMerge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !detail.listedChecks.isEmpty {
                Button { folds.toggle("checks") } label: {
                    row(symbol: symbol, color: color, text: detail.checksSummary, isCollapsed: !isOpen)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("checks-header")
                if isOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(detail.checkGroups) { PRCheckLines(group: $0, folds: folds) }
                    }
                    .transition(.fold)
                }
                Divider()
            }
            reviewers
            Divider()
            row(symbol: merge.symbol, color: merge.color, text: merge.text, isCollapsed: nil)
                .overlay(alignment: .trailing) { mergeAction.padding(.trailing, PRStyle.inset) }
        }
        .prCard()
        .confirmationDialog("Merge this PR?", isPresented: $isConfirmingMerge, titleVisibility: .visible) {
            Button(mergeTitle) { Task { await session.merge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.title)
        }
    }

    /// PolicyBot's word decides, where the repo has it. GitHub's clean state alone is not an approval.
    private var isReadyToMerge: Bool {
        ["CLEAN", "HAS_HOOKS"].contains(detail.mergeState) && (detail.policy?.state ?? "approved") == "approved"
    }

    private var mergeTitle: String {
        switch detail.mergeMethod {
        case "SQUASH": "Squash and merge"
        case "REBASE": "Rebase and merge"
        default: "Merge"
        }
    }

    /// Nothing for a PR that is merged or closed: its row says so.
    @ViewBuilder private var mergeAction: some View {
        if detail.state == "merged" || detail.state == "closed" {
            EmptyView()
        } else if session.isMerged {
            Text("Merged")
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(Color.toneMerged)
        } else if detail.mergeState == "BEHIND" {
            Button(session.isUpdatingBranch ? "Updating…" : "Update") { Task { await session.updateBranch() } }
                .buttonStyle(PRButtonStyle(.secondary))
                .disabled(session.isUpdatingBranch)
                .accessibilityIdentifier("update-branch")
        } else if isReadyToMerge {
            Button("Merge") { isConfirmingMerge = true }
                .buttonStyle(PRButtonStyle(.primary))
                .tint(Color.toneGood)
                .accessibilityIdentifier("merge-pr")
        }
    }

    /// Who is on the review, as GitHub shows it. Nothing here counts them: that is PolicyBot's job.
    @ViewBuilder private var reviewers: some View {
        let people = detail.reviewers ?? []
        if people.isEmpty {
            row(symbol: review.symbol, color: review.color, text: review.text, isCollapsed: nil)
        } else {
            let isOpen = folds.isFlipped("reviewers")
            Button { folds.toggle("reviewers") } label: {
                row(symbol: review.symbol, color: review.color, text: review.text, isCollapsed: !isOpen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reviewers-header")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(people) { reviewer($0) }
                    if let url = detail.policy?.url.flatMap(URL.init(string:)) {
                        Button("PolicyBot details") { PRPlatform.openExternally(url) }
                            .buttonStyle(PRButtonStyle(.plain))
                    }
                }
                .padding(.bottom, Space.xs)
                .transition(.fold)
            }
        }
    }

    private func reviewer(_ person: PullRequestDetail.Reviewer) -> some View {
        let state: Status = switch person.state {
        case "APPROVED": Status(AppIcon.reviewApproved.symbol, Color.toneGood, "Approved")
        case "CHANGES_REQUESTED": Status(AppIcon.reviewChangesRequested.symbol, Color.toneBad, "Changes requested")
        case "COMMENTED": Status(AppIcon.reviewCommented.symbol, .secondary, "Commented")
        case "DISMISSED": Status(AppIcon.reviewDismissed.symbol, .secondary, "Dismissed")
        default: Status(AppIcon.reviewWaiting.symbol, Color.toneWaiting, "Waiting")
        }
        return HStack(spacing: Space.sm) {
            PRAvatar(author: .init(login: person.login, avatarUrl: person.avatarUrl))
            Text(person.login)
                .font(.appCaption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(state.text)
                .font(.appCaption)
                .foregroundStyle(.secondary)
            Image(systemName: state.symbol)
                .font(.appCaption)
                .foregroundStyle(state.color)
        }
        .padding(.horizontal, PRStyle.inset)
        .padding(.vertical, PRStyle.listRowPadding)
    }

    private var deciding: [PullRequestDetail.Check] { detail.decidingChecks }

    private var failing: Int { deciding.filter { $0.state == "failure" }.count }
    private var pending: Int { deciding.filter { $0.state == "pending" }.count }
    private var isOpen: Bool { folds.isFlipped("checks") != (failing > 0) }
    private var symbol: String {
        if deciding.isEmpty {
            return AppIcon.checksNone.symbol
        }
        return (failing > 0 ? AppIcon.checksFail : pending > 0 ? AppIcon.checksRunning : AppIcon.checksPass).symbol
    }

    private var color: Color {
        deciding.isEmpty ? .secondary : Color(failing > 0 ? "ToneBad" : pending > 0 ? "ToneWaiting" : "ToneGood")
    }

    private struct Status {
        let symbol: String
        let color: Color
        let text: String

        init(_ symbol: String, _ color: Color, _ text: String) {
            self.symbol = symbol
            self.color = color
            self.text = text
        }

        /// What a list says about the same thing, in the same words, symbol and colour.
        init(_ mark: PrStatusMark?) {
            self.init(mark?.symbol ?? AppIcon.unknown.symbol, mark?.tone.color ?? .secondary, mark?.text ?? "Unknown")
        }
    }

    /// People only: the Worker counts `.policy.yml`'s approvers where there is one, and PolicyBot's checks sit with
    /// the other checks.
    private var review: Status {
        typealias Review = PullRequestStatus.Review
        return switch detail.reviewDecision {
        case "APPROVED": Status(Review.approved.mark)
        case "CHANGES_REQUESTED": Status(Review.changesRequested.mark)
        case "REVIEW_REQUIRED": Status(Review.required.mark)
        default: Status(AppIcon.reviewNotRequired.symbol, .secondary, "No review required")
        }
    }

    private var merge: Status {
        typealias Merge = PullRequestStatus.Merge
        switch detail.state {
        case "merged": return Status(AppIcon.merged.symbol, Color.toneMerged, "Merged")
        case "closed": return Status(AppIcon.closed.symbol, .secondary, "Closed")
        default: break
        }
        return switch detail.mergeState {
        case "CLEAN", "HAS_HOOKS": Status(Merge.clean.mark)
        case "BEHIND": Status(Merge.behind.mark)
        case "DIRTY": Status(Merge.conflicting.mark)
        case "BLOCKED": Status(Merge.blocked.mark)
        case "UNSTABLE": Status(AppIcon.mergeableFailing.symbol, Color.toneWaiting, "Mergeable with failing checks")
        default: Status(AppIcon.unknown.symbol, .secondary, "Merge state unknown")
        }
    }

    private func row(symbol: String, color: Color, text: String, isCollapsed: Bool?) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text).font(.appFootnote)
            Spacer()
            if let isCollapsed {
                PRChevron(isCollapsed: isCollapsed)
            }
        }
        .padding(PRStyle.inset)
        .contentShape(.rect)
    }
}

/// One line of the checks: a single check, or a job's legs under one line that opens to them; a failing one opens by
/// itself.
private struct PRCheckLines: View {
    let group: PullRequestDetail.CheckGroup
    let folds: FoldSet

    /// Skipped covers cancelled runs too: GitHub's overall state doesn't count them, so neither does the summary.
    private static func color(_ state: String) -> Color {
        switch state {
        case "failure": Color.toneBad
        case "pending": Color.toneWaiting
        case "skipped": .secondary
        default: Color.toneGood
        }
    }

    private static func symbol(_ state: String) -> String {
        switch state {
        case "failure": AppIcon.checksFail.symbol
        case "pending": AppIcon.checksRunning.symbol
        case "skipped": AppIcon.checkSkipped.symbol
        default: AppIcon.checksPass.symbol
        }
    }

    @ViewBuilder var body: some View {
        if group.isGroup {
            let isOpen = folds.isFlipped("check-group:\(group.id)") != (group.state == "failure")
            Button { folds.toggle("check-group:\(group.id)") } label: {
                checkLine(name: group.name, detail: group.detail, state: group.state, required: group.required) {
                    PRChevron(isCollapsed: !isOpen)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("check-group-\(group.name)")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if let job = group.job {
                        check(job, name: job.name)
                    }
                    ForEach(group.legs) { check($0.check, name: $0.label) }
                }
                .padding(.leading, Space.lg)
                .transition(.fold)
            }
        } else if let job = group.job {
            check(job, name: job.name, detail: group.detail)
        }
    }

    private func check(_ check: PullRequestDetail.Check, name: String, detail: String? = nil) -> some View {
        Button {
            if let url = check.url.flatMap(URL.init(string:)) {
                PRPlatform.openExternally(url)
            }
        } label: {
            checkLine(name: name, detail: detail, state: check.state, required: check.required) {
                if check.url != nil {
                    Image(AppIcon.openExternally)
                        .font(.appCaption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// A check's line: its state, its name, what tells it apart (quieter), whether it is required, and what a tap does.
    private func checkLine(
        name: String, detail: String?, state: String, required: Bool?, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: Self.symbol(state))
                .font(.appCaption)
                .foregroundStyle(Self.color(state))
            HStack(spacing: Space.xs) {
                Text(name)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail {
                    Text(verbatim: "· \(detail)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.appCaption)
            if required != false {
                Image(AppIcon.required)
                    .font(.appCaption2)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [name, detail, required == false ? nil : "required"].compactMap(\.self).joined(separator: ", ")
        )
        .accessibilityValue(state)
        .padding(.horizontal, PRStyle.inset)
        .padding(.vertical, PRStyle.listRowPadding)
        .contentShape(.rect)
    }
}
