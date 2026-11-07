import PRKitCore
import PRKitDesign
import SwiftUI

/// One item of a list, across the whole width, led by its PRs: each a row that opens the PR, then the agent's note, then the
/// ticket, hanging off a line from the avatar. An item with no PR leads with its ticket. DESIGN.md is the contract.
public struct PrListBlock: View {
    public let item: PRListItem
    /// Where the block is in the list, for its folds.
    public let id: String
    /// When the agent sent this version of the list: only what Jai decided after it fades a row.
    public let sentAt: Date
    public let now: Date
    public var format = ThreadTimeFormat()
    /// When Jai opened each PR here, by `PullRequest.key`.
    public var opened: [String: Date] = [:]
    public var onOpen: (PRListPullRequest) -> Void = { _ in }
    public let folds: FoldSet

    public init(
        item: PRListItem, id: String, sentAt: Date, now: Date, format: ThreadTimeFormat = ThreadTimeFormat(),
        opened: [String: Date] = [:], onOpen: @escaping (PRListPullRequest) -> Void = { _ in }, folds: FoldSet
    ) {
        self.item = item
        self.id = id
        self.sentAt = sentAt
        self.now = now
        self.format = format
        self.opened = opened
        self.onOpen = onOpen
        self.folds = folds
    }
    #if os(macOS)
    private var avatarSize: CGFloat { PrListGrid.avatar * MacTextSize.scale }
    #else
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize = PrListGrid.avatar
    #endif

    /// Where text starts: past the avatar, which grows with the text.
    private var textColumn: CGFloat {
        avatarSize + PrListGrid.gutter
    }

    private var hasFoot: Bool {
        !item.pullRequests.isEmpty && item.ticket != nil
    }

    public var body: some View {
        let opacity = item.isDecidedByJai(since: sentAt) ? PrListGrid.fadedOpacity : 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.pullRequests.enumerated()), id: \.offset) { index, pullRequest in
                pullRequestRow(pullRequest)
                    .padding(.top, index == 0 ? 0 : Space.lg)
            }
            if item.pullRequests.isEmpty {
                ticketRow
            }
            if let note = item.note {
                PrListNote(text: note, id: id, folds: folds)
                    .padding(.leading, textColumn)
                    .padding(.top, Space.sm)
                    .opacity(opacity)
            }
            if hasFoot, let ticket = item.ticket {
                ticketLine(ticket)
                    .opacity(opacity)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, hasFoot ? 0 : Space.md)
        .backgroundPreferenceValue(TicketLineBounds.self) { bounds in
            GeometryReader { proxy in
                if let bounds {
                    TicketRail(leading: 16 + avatarSize / 2, top: 12 + avatarSize / 2, end: proxy[bounds])
                        .stroke(.separator, lineWidth: 1)
                }
            }
        }
        .background(Color.groundCard)
    }

    private func pullRequestRow(_ pullRequest: PRListPullRequest) -> some View {
        let opacity = pullRequest.isDecidedByJai(since: sentAt) ? PrListGrid.fadedOpacity : 1
        return PrListLink(url: pullRequest.url, onOpen: { onOpen(pullRequest) }, content: {
            HStack(alignment: .top, spacing: PrListGrid.gutter) {
                VStack(spacing: Space.xs) {
                    PrAuthorAvatar(pullRequest: pullRequest)
                        .background(Color.groundCard, in: .circle)
                        .opacity(opacity)
                    if let due = pullRequest.pastSLA(now: now) {
                        PrPastSLAMark(due: due, now: now, format: format)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .top, spacing: Space.sm) {
                        title(item.title(of: pullRequest))
                        PrStateIcon(state: pullRequest.listState)
                            .padding(.vertical, -Space.xxs)
                    }
                    .opacity(opacity)
                    metaLine(pullRequest)
                        .opacity(opacity)
                    let signals = pullRequest.status.signalMarks
                    if !signals.isEmpty {
                        PrStatusMarks(marks: signals)
                            .opacity(opacity)
                    }
                    if let mark = pullRequest.jaiMark(openedAt: opened[pullRequest.key], now: now, format: format) {
                        PrJaiMarkLabel(mark: mark)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        })
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.appSubheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The name goes first, then the repository's front; the number and the age stay.
    private func metaLine(_ pullRequest: PRListPullRequest) -> some View {
        ViewThatFits(in: .horizontal) {
            metaText(pullRequest, showsAuthor: true)
                .fixedSize()
            metaText(pullRequest, showsAuthor: false)
                .truncationMode(.head)
        }
    }

    private func metaText(_ pullRequest: PRListPullRequest, showsAuthor: Bool) -> some View {
        // Grey as a colour, not `.secondary`: inside the phone's borderless button that would be a paler tint.
        Text(item.metaLine(of: pullRequest, now: now, format: format, showsAuthor: showsAuthor))
            .font(.appCaption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
    }

    /// An item with no PR: the same places, with Linear's mark for the avatar and the key for the reference.
    private var ticketRow: some View {
        PrListLink(url: item.ticket?.url) {
            HStack(alignment: .top, spacing: PrListGrid.gutter) {
                LinearMark(size: 22)
                    .frame(width: avatarSize, height: avatarSize)
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .top, spacing: Space.sm) {
                        title(item.ticket?.title ?? item.title ?? item.ticket?.key ?? "")
                        if let ticket = item.ticket {
                            LinearStateCircle(ticket: ticket)
                                .frame(height: PrListGrid.titleLine)
                        }
                    }
                    if let ticket = item.ticket {
                        Text("\(ticket.key) · \(ticket.stateText)")
                            .font(.appCaption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
    }

    /// The key, the title in what room is left, and where the ticket stands. The whole line opens Linear.
    private func ticketLine(_ ticket: PRListTicket) -> some View {
        PrListLink(url: ticket.url) {
            TicketLine(ticket: ticket)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .anchorPreference(key: TicketLineBounds.self, value: .bounds) { $0 }
        .padding(.leading, textColumn + PrListGrid.ticketStep)
    }
}

private struct TicketLineBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The line from the first avatar down to the ticket, turning right to stop just short of its mark.
private struct TicketRail: Shape {
    let leading: CGFloat
    let top: CGFloat
    let end: CGRect
    private static let gap: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: leading, y: top))
        path.addLine(to: CGPoint(x: leading, y: end.midY))
        path.addLine(to: CGPoint(x: end.minX - Self.gap, y: end.midY))
        return path
    }
}

/// Under the avatar of a review past its SLA: a red clock and how long ago it was due.
public struct PrPastSLAMark: View {
    public let due: Date
    public let now: Date
    public let format: ThreadTimeFormat

    public var body: some View {
        // design-lint: allow the clock and its age read as one mark under the avatar
        VStack(spacing: 1) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .font(.appCaption)
            Text(format.age(due, now: now))
                .font(.appCaption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(Color.toneBad)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Past review SLA, due \(format.ago(due, now: now))")
        .accessibilityIdentifier("pr-past-sla")
    }
}
