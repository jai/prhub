import PRKitCore
import PRKitDesign
import SwiftUI

/// The way from a PR into its diff, as GitHub has it: a Files changed row with the lines added and removed, and Review
/// changes. Both push the diff over the PR, so Back from it is the PR; Review changes opens its panel on the key lines.
struct PRChangesCard: View {
    let detail: PullRequestDetail
    let showDiff: () -> Void
    let reviewChanges: () -> Void

    private var filesLabel: some View {
        Label("Files changed · \(detail.changedFiles)", systemImage: AppIcon.reviewChanges.symbol)
            .labelStyle(.iconText)
            .font(.appFootnote.weight(.semibold))
            .foregroundStyle(Color.primary)
    }

    /// The lines added and removed, and the chevron into the diff.
    @ViewBuilder private var counts: some View {
        Text(verbatim: "+\(detail.additions)")
            .foregroundStyle(Color.toneGood)
        Text(verbatim: "−\(detail.deletions)")
            .foregroundStyle(Color.toneBad)
        Image(systemName: AppIcon.drillIn.symbol)
            .foregroundStyle(Color.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: showDiff) {
                // On one line while it fits; in the largest text the counts go under the words, which squeezed beside
                // them broke "changed" a letter or two to a line (CI's picture, 2026-11-14).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.sm) {
                        filesLabel
                        Spacer(minLength: Space.sm)
                        counts
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        filesLabel
                        HStack(spacing: Space.sm) {
                            counts
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.appCaption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, PRStyle.inset)
                .frame(minHeight: PRStyle.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Files changed, \(detail.changedFiles), \(detail.additions) added, \(detail.deletions) removed")
            .accessibilityIdentifier("pr-files-changed")
            Divider()
            Button(action: reviewChanges) {
                Label("Review changes", systemImage: AppIcon.reviewChanges.symbol)
                    .labelStyle(.iconText)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PRButtonStyle(.primary))
            .padding(PRStyle.inset)
            .accessibilityIdentifier("pr-review-changes")
        }
        .prCard()
    }
}
