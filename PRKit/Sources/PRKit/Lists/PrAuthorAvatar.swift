import PRKitCore
import PRKitDesign
import SwiftUI

/// A PR author's GitHub picture in a circle, their initials while it loads or where GitHub has none. With no author known
/// it draws nothing: the column stays, and there is no empty circle.
public struct PrAuthorAvatar: View {
    public let pullRequest: PRListPullRequest
    @Environment(\.loadsAuthorAvatars) private var loadsAvatars
    #if os(macOS)
    private var size: CGFloat { 32 * MacTextSize.scale }
    #else
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 32
    #endif

    public var body: some View {
        if let initials {
            AsyncImage(
                url: loadsAvatars ? pullRequest.avatarURL : nil,
                transaction: Transaction(animation: .easeOut(duration: 0.2))
            ) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(.quaternary)
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    /// "AS" for Aymen Sakouhi; a login's first letter where GitHub has no name.
    private var initials: String? {
        if let words = pullRequest.authorName?.split(separator: " "), let first = words.first?.first {
            return String([first] + (words.dropFirst().last?.first.map { [$0] } ?? [])).uppercased()
        }
        return pullRequest.author?.first.map { String($0).uppercased() }
    }
}

extension EnvironmentValues {
    /// Off over PRHub's sample PRs: their authors are made up, so no picture is fetched from GitHub for them.
    @Entry public var loadsAuthorAvatars = true
}
