import PRKitCore
import PRKitDesign
import SwiftUI

/// A ticket on one line: Linear's mark, the key, the title in what room is left, then who owns it and where it stands,
/// always at the right edge. It is how a ticket looks wherever it supports something else.
public struct TicketLine: View {
    public let ticket: PRListTicket
    /// Whether a ticket Linear hasn't answered for is still being looked up (a list's hub resolves it) and says so. A
    /// PR's page has the Worker's last word: there, unanswered means no Linear to ask, and the line is the key alone.
    public var awaitsLinear = true
    /// Whether an unanswered ticket says why and what to do: the person hasn't connected Linear (`connectLinear`).
    public var asksToConnectLinear = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(ticket: PRListTicket, awaitsLinear: Bool = true, asksToConnectLinear: Bool = false) {
        self.ticket = ticket
        self.awaitsLinear = awaitsLinear
        self.asksToConnectLinear = asksToConnectLinear
    }

    public static let connectLinearWords = "Connect Linear to see this ticket"

    public var body: some View {
        HStack(spacing: Space.sm) {
            LinearMark()
            Text(ticket.key)
                .fixedSize()
            if asksToConnectLinear, ticket.found == nil {
                Text(Self.connectLinearWords)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                if let title = ticket.title, dynamicTypeSize < .xxLarge {
                    Text(title)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The owner by first name, so the title keeps its room; it gives way after the title, and goes with it
                // at xxLarge and up.
                if let assignee = ticket.assignee, ticket.found == true, dynamicTypeSize < .xxLarge {
                    Text(ticket.ownerShortName ?? assignee)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityLabel("Assigned to \(assignee)")
                }
                if awaitsLinear || ticket.found != nil {
                    Text(ticket.stateText)
                        .fixedSize()
                    LinearStateCircle(ticket: ticket)
                }
            }
        }
        .font(.appCaption)
        .foregroundStyle(Color.secondary)
    }
}

/// A ticket as a button that opens it: in Linear's app when it is installed, else in a browser sheet over the page, so a
/// look at a ticket never leaves the PR (`PRPlatform.openInItsAppOrHere`). It keeps the line's quiet look and shows its
/// ground while pressed; VoiceOver says the ticket, then that it opens in Linear. Its own button, apart from the row
/// it is on. Just what it holds when there is no page to open.
public struct TicketLink<Content: View>: View {
    public let ticket: PRListTicket
    @ViewBuilder public let content: Content

    public init(ticket: PRListTicket, @ViewBuilder content: () -> Content) {
        self.ticket = ticket
        self.content = content()
    }

    public var body: some View {
        if let destination = ticket.url.flatMap(PrListLinks.openable) {
            Button {
                PRPlatform.openInItsAppOrHere(destination)
            } label: {
                content
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(TicketLinkStyle())
            .accessibilityLabel(ticket.spokenLine)
            .accessibilityHint("Opens in Linear")
            .accessibilityIdentifier("pr-ticket-\(ticket.key)")
        } else {
            content
        }
    }
}

/// A line that is a button and still reads as the quiet line it is: pressed, it dims on a ground a little wider than
/// its words.
private struct TicketLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? PRStyle.pressedOpacity : 1)
            .background {
                RoundedRectangle(cornerRadius: PRStyle.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color.groundFill : .clear)
                    .padding(.horizontal, -Space.xs)
            }
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

/// What a ticket Linear wasn't asked about opens instead of Linear: where the person connects Linear. Set by an app
/// whose person can connect Linear and hasn't (PRHub's hosted account); nil everywhere else, and the line is the key.
public struct ConnectLinear: Sendable {
    public let open: @MainActor @Sendable () -> Void

    public init(open: @escaping @MainActor @Sendable () -> Void) {
        self.open = open
    }
}

public extension EnvironmentValues {
    @Entry var connectLinear: ConnectLinear?
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

    /// A ticket Linear wasn't asked about, on a line with the last word on it (`awaitsLinear` false), where the person
    /// can connect Linear: its line says so and opens that setting.
    func asksToConnectLinear(canConnect: Bool, awaitsLinear: Bool) -> Bool {
        guard canConnect, !awaitsLinear, case let .ticket(ticket) = object else {
            return false
        }
        return ticket.found == nil
    }
}

/// One PR or ticket on its line, drawn as everywhere else. Its whole width opens it: a PR through `openURL`, in the
/// GitHub app when installed, and a ticket as `TicketLink` does.
public struct ObjectReferenceLine: View {
    public let reference: ObjectReference
    public var awaitsLinear = true
    /// Whether the line is a row high (`PRStyle.rowHeight`), the least a finger needs: a PR's page, where its lines
    /// stand on their own. Off where they sit close under something else that is tapped (a thread's row).
    public var isRowHigh = false
    @Environment(\.connectLinear) private var connectLinear

    public init(reference: ObjectReference, awaitsLinear: Bool = true, isRowHigh: Bool = false) {
        self.reference = reference
        self.awaitsLinear = awaitsLinear
        self.isRowHigh = isRowHigh
    }

    /// A ticket the Worker had no Linear to ask about, where the person can connect Linear: the line says so and opens
    /// that setting.
    private var asksToConnectLinear: Bool {
        reference.asksToConnectLinear(canConnect: connectLinear != nil, awaitsLinear: awaitsLinear)
    }

    public var body: some View {
        if asksToConnectLinear, let connectLinear {
            Button {
                connectLinear.open()
            } label: {
                line
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens Linear in Settings")
            .accessibilityIdentifier("pr-ticket-connect-linear")
        } else if case let .ticket(ticket) = reference.object {
            TicketLink(ticket: ticket) {
                line
            }
        } else {
            PrListLink(url: reference.url) {
                line
            }
        }
    }

    private var line: some View {
        Group {
            switch reference.object {
            case let .pullRequest(pullRequest): PullRequestLine(pullRequest: pullRequest)
            case let .ticket(ticket):
                TicketLine(ticket: ticket, awaitsLinear: awaitsLinear, asksToConnectLinear: asksToConnectLinear)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isRowHigh ? PRStyle.rowHeight : nil, alignment: .leading)
        .contentShape(.rect)
    }
}

/// Several PRs or tickets, one line each, each opening its page: Agent Pager's thread accessory and a PR's tickets.
public struct ObjectReferenceLines: View {
    public let references: [ObjectReference]
    public var awaitsLinear = true
    /// Each line a row high, one under the other with no gap: a finger's height each (`ObjectReferenceLine.isRowHigh`).
    public var isRowHigh = false

    public init(references: [ObjectReference], awaitsLinear: Bool = true, isRowHigh: Bool = false) {
        self.references = references
        self.awaitsLinear = awaitsLinear
        self.isRowHigh = isRowHigh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: isRowHigh ? 0 : PRStyle.referenceGap) {
            ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                ObjectReferenceLine(reference: reference, awaitsLinear: awaitsLinear, isRowHigh: isRowHigh)
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
