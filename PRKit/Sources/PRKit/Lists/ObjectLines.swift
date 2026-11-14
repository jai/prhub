import PRKitCore
import PRKitDesign
import SwiftUI

/// A ticket on one line: Linear's mark, the key, the title in what room is left, and where it stands, always at the right
/// edge. It is how a ticket looks wherever it supports something else.
public struct TicketLine: View {
    public let ticket: PRListTicket
    /// Whether a ticket Linear hasn't answered for is still being looked up (a list's hub resolves it) and says so. A
    /// PR's page has the Worker's last word: there, unanswered means no Linear to ask, and the line is the key alone.
    public var awaitsLinear = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(ticket: PRListTicket, awaitsLinear: Bool = true) {
        self.ticket = ticket
        self.awaitsLinear = awaitsLinear
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
            if awaitsLinear || ticket.found != nil {
                Text(ticket.stateText)
                    .fixedSize()
                LinearStateCircle(ticket: ticket)
            }
        }
        .font(.appCaption)
        .foregroundStyle(Color.secondary)
    }
}

/// A PR or ticket that something else names, and the page it opens: what a thread's row folds in under it and what a
/// PR's page lists under its title.
public struct ObjectReference: Equatable, Sendable {
    public enum Object: Equatable, Sendable {
        case pullRequest(PRListPullRequest)
        case ticket(PRListTicket)
    }

    public var object: Object
    /// Nil where there is no page to open: a ticket the Worker couldn't ask Linear about.
    public var url: String?

    public init(object: Object, url: String?) {
        self.object = object
        self.url = url
    }

    public init(_ pullRequest: PRListPullRequest) {
        self.init(object: .pullRequest(pullRequest), url: pullRequest.url)
    }

    public init(_ ticket: PRListTicket) {
        self.init(object: .ticket(ticket), url: ticket.url)
    }
}

/// One PR or ticket on its line, drawn as everywhere else. Its whole width opens it, in the GitHub or Linear app when
/// installed.
public struct ObjectReferenceLine: View {
    public let reference: ObjectReference
    public var awaitsLinear = true

    public init(reference: ObjectReference, awaitsLinear: Bool = true) {
        self.reference = reference
        self.awaitsLinear = awaitsLinear
    }

    public var body: some View {
        PrListLink(url: reference.url) {
            Group {
                switch reference.object {
                case let .pullRequest(pullRequest): PullRequestLine(pullRequest: pullRequest)
                case let .ticket(ticket): TicketLine(ticket: ticket, awaitsLinear: awaitsLinear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
    }
}

/// Several PRs or tickets, one line each, each opening its page: Agent Pager's thread accessory and a PR's tickets.
public struct ObjectReferenceLines: View {
    public let references: [ObjectReference]
    public var awaitsLinear = true

    public init(references: [ObjectReference], awaitsLinear: Bool = true) {
        self.references = references
        self.awaitsLinear = awaitsLinear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PRStyle.referenceGap) {
            ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                ObjectReferenceLine(reference: reference, awaitsLinear: awaitsLinear)
            }
        }
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
