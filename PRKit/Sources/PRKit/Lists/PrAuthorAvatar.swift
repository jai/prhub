import PRKitCore
import PRKitDesign
import SwiftUI

/// A PR author's GitHub picture in a circle, their initials while it loads or where GitHub has none. A bot's PR with
/// someone behind it shows that person instead (`PRListPullRequest.avatarURL`). With no one known it draws nothing: the
/// column stays, and there is no empty circle.
public struct PrAuthorAvatar: View {
    public let pullRequest: PRListPullRequest
    @Environment(\.loadsAuthorAvatars) private var loadsAvatars
    @Environment(\.avatarPictures) private var pictures
    #if os(macOS)
        private var size: CGFloat {
            32 * MacTextSize.layoutScale
        }
    #else
        @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 32
    #endif

    public var body: some View {
        if let initials {
            face(initials)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) { agentMark }
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func face(_ initials: String) -> some View {
        if let picture = pullRequest.avatarURL.flatMap({ pictures[$0.absoluteString] }) {
            picture
                .resizable()
                .scaledToFill()
        } else {
            AsyncImage(
                url: loadsAvatars ? pullRequest.avatarURL : nil,
                transaction: Transaction(animation: AppMotion.swap)
            ) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(.quaternary)
                        Text(initials)
                            // swiftlint:disable:next design_font - initials are drawn to the avatar's size, which follows Dynamic Type
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// On a bot's PR with someone behind it, the agent Linear delegated the ticket to: its own picture in Linear, small,
    /// at the person's corner. Only that picture: an agent Linear has none for is named in the meta line alone, never
    /// drawn as initials or as the GitHub account's picture.
    @ViewBuilder private var agentMark: some View {
        if pullRequest.requestedBy != nil, let address = pullRequest.agent?.avatarUrl, let url = URL(string: address) {
            Group {
                if let picture = pictures[address] {
                    picture
                        .resizable()
                        .scaledToFill()
                } else if loadsAvatars {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .frame(width: size * Self.agentScale, height: size * Self.agentScale)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
            .offset(x: size * Self.agentOverhang, y: size * Self.agentOverhang)
            .accessibilityIdentifier("pr-row-agent")
        }
    }

    /// The agent's picture is half the person's, and hangs an eighth of it past the corner.
    private static let agentScale: CGFloat = 0.5
    private static let agentOverhang: CGFloat = 0.125

    private var initials: String? {
        pullRequest.whoInitials
    }
}

public extension EnvironmentValues {
    /// Off over PRHub's sample PRs: their authors are made up, so no picture is fetched from GitHub for them.
    @Entry var loadsAuthorAvatars = true
    /// Pictures already in hand, by the address the Worker gave: a face with one here is drawn from it at once, without
    /// the network. PRHub's sample PRs and the rendering tests set it; empty, every picture is fetched.
    @Entry var avatarPictures: [String: Image] = [:]
}
