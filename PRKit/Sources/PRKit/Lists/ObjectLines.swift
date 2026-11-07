import PRKitCore
import PRKitDesign
import SwiftUI

/// A ticket on one line: Linear's mark, the key, the title in what room is left, and where it stands, always at the right
/// edge. It is how a ticket looks wherever it supports something else.
public struct TicketLine: View {
    public let ticket: PRListTicket
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(ticket: PRListTicket) {
        self.ticket = ticket
    }

    public var body: some View {
        HStack(spacing: Space.sm) {
            LinearMark()
            Text(ticket.key)
                .fixedSize()
            if let title = ticket.title, dynamicTypeSize < .xxLarge {
                Text(title)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(ticket.stateText)
                .fixedSize()
            LinearStateCircle(ticket: ticket)
        }
        .font(.appCaption)
        .foregroundStyle(Color.secondary)
    }
}

/// A PR on one line, for where a block would be too much: the foot of a thread's card. The title gives way, the reference
/// and the state stay, and the state is at the right edge, as on a block.
public struct PullRequestLine: View {
    public let pullRequest: PRListPullRequest
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(pullRequest: PRListPullRequest) {
        self.pullRequest = pullRequest
    }

    public var body: some View {
        HStack(spacing: Space.sm) {
            Text(pullRequest.status.reference)
                .fixedSize()
            if let title = pullRequest.status.title, dynamicTypeSize < .xxLarge {
                Text(title)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PrStateIcon(state: pullRequest.listState)
        }
        .font(.appCaption)
        .foregroundStyle(Color.secondary)
    }
}
