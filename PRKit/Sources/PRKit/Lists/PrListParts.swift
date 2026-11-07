import PRKitCore
import PRKitDesign
import SwiftUI

/// The columns every row of a list shares (DESIGN.md).
public enum PrListGrid {
    public static let avatar = RowGrid.leading
    public static let gutter = RowGrid.gutter
    /// How far a ticket sits inside the title, so it reads as under the PR, not beside it.
    public static let ticketStep: CGFloat = 16
    /// The right edge's one column: a PR's state, a ticket's circle.
    public static let state: CGFloat = 24
    /// A title's first line, which a state in that column centres on.
    public static let titleLine: CGFloat = 20
    /// A row Jai is done with for now: decided by him, or his answer with the agent. A thread's row fades the same.
    public static let fadedOpacity = 0.6
}

/// Which links a row opens.
public enum PrListLinks {
    /// `https` with a host only. Anything else is shown but not opened.
    public static func openable(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

/// A ticket or PR line that opens its URL — in the Linear or GitHub app when installed — through the check a
/// thread's links pass (`SessionLink.openable`); plain text when there is nothing to open. Borderless, so each line
/// of a row is its own button. `onOpen` runs as it opens.
public struct PrListLink<Content: View>: View {
    public let url: String?
    public var onOpen: () -> Void = {}
    @ViewBuilder public let content: Content
    @Environment(\.openURL) private var openURL

    public init(url: String?, onOpen: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.url = url
        self.onOpen = onOpen
        self.content = content()
    }

    public var body: some View {
        if let destination = url.flatMap(PrListLinks.openable) {
            Button {
                onOpen()
                openURL(destination)
            } label: {
                content
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens \(destination.absoluteString)")
        } else {
            content
        }
    }
}

/// A PR's one state: GitHub's own symbol in a round tint, always in the right edge's column.
public struct PrStateIcon: View {
    public let state: PrListState

    public var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundStyle(color)
            .frame(width: PrListGrid.state, height: PrListGrid.state)
            .background(color.opacity(0.15), in: .circle)
            .accessibilityLabel(state.rawValue)
    }

    private var image: Image {
        switch state {
        case .open: Image("GitHubPROpen")
        case .draft: Image("GitHubPRDraft")
        case .merged: Image("GitHubPRMerged")
        case .closed: Image("GitHubPRClosed")
        case .resolving: Image(systemName: "clock")
        case .notFound: Image(systemName: "questionmark.circle")
        }
    }

    private var color: Color {
        switch state {
        case .open: Color.toneGood
        case .merged: Color.toneMerged
        case .closed: Color.toneBad
        case .notFound: Color.toneWaiting
        case .draft, .resolving: Color.secondary
        }
    }
}

/// A PR's status marks, each its symbol close to its words in its tone, wrapped to the row's width.
public struct PrStatusMarks: View {
    public let marks: [PrStatusMark]

    public var body: some View {
        FlowLayout(spacing: Space.md) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Label(mark.text, systemImage: mark.symbol)
                    .labelStyle(.iconText)
                    .font(.appCaption)
                    .foregroundStyle(mark.tone.color)
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

extension PrStatusMark.Tone {
    public var color: Color {
        switch self {
        case .good: Color.toneGood
        case .bad: Color.toneBad
        case .waiting: Color.toneWaiting
        case .quiet: Color.secondary
        case .merged: Color.toneMerged
        }
    }
}

/// What Jai has done with a PR, under its line, in grey: "Asked again" and "You're blocking" are coloured, because they
/// want something of him. His approval is a person with a check, as every review is (AppIcon); passing checks are a dot.
/// It stays at full strength when the row fades: it is why the row faded.
public struct PrJaiMarkLabel: View {
    public let mark: PrJaiMark

    public var body: some View {
        Group {
            if mark.kind == .approved {
                IconText(mark.text, icon: .reviewApproved)
            } else {
                Text(mark.text)
            }
        }
        .font(.appCaption)
        .foregroundStyle(tone)
    }

    private var tone: Color {
        switch mark.kind {
        case .approved: Color.toneGood
        case .blocking: Color.toneBad
        case .askedAgain: Color.toneWaiting
        default: Color.secondary
        }
    }
}

/// The agent's sentence for a block. It folds at four lines and opens in place.
public struct PrListNote: View {
    public let text: String
    public let id: String
    public let folds: FoldSet
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private static let foldedLines = 4

    public var body: some View {
        let isOpen = folds.isFlipped(id)
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(text)
                .font(.appFootnote)
                .foregroundStyle(Color.primary)
                .lineLimit(isOpen ? nil : Self.foldedLines)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                .background {
                    Text(text)
                        .font(.appFootnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                }
            if !isOpen, fullHeight > shownHeight + 1 {
                Button("More") { folds.toggle(id) }
                    .font(.appFootnote)
                    .buttonStyle(.borderless)
            }
        }
    }
}
