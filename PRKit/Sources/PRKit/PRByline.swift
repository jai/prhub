import PRKitCore
import PRKitDesign
import SwiftUI

/// Who a PR is from, then its branch and base on a line of their own. A bot's PR leads with the person it was opened for,
/// and the bot is a quiet chip after them: the agent Linear delegated the ticket to, as Linear has it, then the account
/// that opened the PR.
struct PRByline: View {
    let detail: PullRequestDetail
    /// Under the person's name: past their face.
    private static let branchIndent: CGFloat = 20 + Space.xs

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // At a large text size the chip goes under the person.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) { who }
                VStack(alignment: .leading, spacing: Space.xs) { who }
            }
            Text("\(detail.headBranch) → \(detail.base)")
                .font(.app(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Self.branchIndent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail.byline) wants \(detail.headBranch) in \(detail.base)")
        .accessibilityIdentifier("pr-author")
    }

    @ViewBuilder private var who: some View {
        if let person = detail.requesterShortName {
            HStack(spacing: Space.xs) {
                PRAvatar(author: detail.bylineAvatar)
                Text(person)
                    .font(.appCaption.weight(.semibold))
                Text("via")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            bot
        } else if detail.agent != nil {
            bot
        } else {
            HStack(spacing: Space.xs) {
                PRAvatar(author: detail.author)
                Text(detail.byline)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }

    private var bot: some View {
        let login = detail.author?.login ?? "ghost"
        return HStack(spacing: Space.xs) {
            PRAvatar(author: detail.agent ?? detail.author)
            if let agent = detail.agent {
                Text(agent.login)
                    .font(.appCaption.weight(.medium))
                    .layoutPriority(1)
                Text("· \(login)")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(login) (bot)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(Space.xxs)
        .padding(.trailing, Space.xs)
        .background(Color.groundFill, in: Capsule())
    }
}
