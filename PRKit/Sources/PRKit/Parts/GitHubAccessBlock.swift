import PRKitCore
import PRKitDesign
import SwiftUI

/// Where a GitHub App reaches for the person: each account it is installed on, opening that installation's settings on
/// GitHub, and the way to install it on another account. Settings' "GitHub access" block (DESIGN.md, Page and block).
public struct GitHubAccessBlock: View {
    let appName: String
    let installations: [GitHubInstallation]
    let installURL: URL
    let isChecking: Bool

    /// `appName` names the App in the block's words ("PRHub"); `installURL` is its `installations/new` page.
    /// `isChecking` while the host reads the installations again, back from GitHub.
    public init(appName: String, installations: [GitHubInstallation], installURL: URL, isChecking: Bool = false) {
        self.appName = appName
        self.installations = installations
        self.installURL = installURL
        self.isChecking = isChecking
    }

    public var body: some View {
        PRPageBlock(
            "GitHub access",
            note: "\(appName) sees pull requests only where its GitHub App is installed. An org owner installs it; a "
                + "member can ask for it on the same page. Tap an account to change its repositories on GitHub."
        ) {
            if isChecking {
                HStack(spacing: Space.sm) {
                    ProgressView()
                    Text("Checking GitHub…")
                        .font(.appFootnote)
                        .foregroundStyle(Color.inkQuiet)
                }
                .transition(.fold)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("github-access-checking")
            } else if installations.isEmpty {
                Text("\(appName) isn't installed on any of your accounts yet.")
                    .font(.appFootnote)
                    .foregroundStyle(Color.inkQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.fold)
                    .accessibilityIdentifier("github-access-none")
            }
            ForEach(installations) { installation in
                GitHubInstallationLine(installation)
                    .transition(.fold)
            }
            Link(destination: installURL) {
                Label("Add another account", systemImage: AppIcon.installApp.symbol)
                    .labelStyle(.iconText)
            }
            .buttonStyle(PRButtonStyle(.secondary))
            .accessibilityIdentifier("github-access-add-account")
        }
        .animation(AppMotion.fold, value: installations)
        .animation(AppMotion.fold, value: isChecking)
    }
}

/// One account the App is installed on: its picture and name, which repositories, and Suspended when GitHub suspended
/// the App there. The whole line opens the installation's settings on GitHub.
public struct GitHubInstallationLine: View {
    let installation: GitHubInstallation

    public init(_ installation: GitHubInstallation) {
        self.installation = installation
    }

    public var body: some View {
        Link(destination: installation.settingsURL) {
            HStack(alignment: .center, spacing: Space.md) {
                PRAvatar(author: .init(login: installation.account, avatarUrl: installation.avatarURL?.absoluteString))
                // Suspended sits at the right while it fits there, and under the words at a large text size.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Space.md) {
                        words
                        Spacer(minLength: 0)
                        suspendedChip
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        words
                        suspendedChip
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(AppIcon.openExternally)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.inkQuiet)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: PRStyle.controlHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(AppMotion.swap, value: installation)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityWords)
        .accessibilityHint("Opens its settings on GitHub")
        .accessibilityIdentifier("github-installation-\(installation.account)")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(installation.account)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text(installation.repositoriesWords)
                .font(.appCaption)
                .foregroundStyle(Color.inkQuiet)
                .contentTransition(.opacity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var suspendedChip: some View {
        if installation.suspended {
            StatusChip(text: "Suspended", tint: .toneBad)
                .fixedSize()
                .transition(.opacity)
        }
    }

    private var accessibilityWords: String {
        let words = [installation.account, installation.repositoriesWords]
        return (words + (installation.suspended ? ["Suspended"] : [])).joined(separator: ", ")
    }
}
