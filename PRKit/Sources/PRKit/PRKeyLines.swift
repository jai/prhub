import PRKitCore
import PRKitDesign
import SwiftUI

/// Where a reviewer should look in a PR, from the model through the Worker (`worker/src/ai.ts`). Every item is a line
/// the diff shows, so a tap always lands.
public struct PRKeyLines: Decodable, Sendable {
    public static let defaultContext = 100

    /// "1 key line", "3 key lines": how many a diff has, where none is selected.
    static func counted(_ count: Int) -> String {
        "\(count) key line\(count == 1 ? "" : "s")"
    }

    public struct Item: Decodable, Identifiable, Sendable {
        public let path: String
        public let line: Int
        public let side: String
        public let kind: String
        public let why: String

        public var id: String {
            "\(path):\(side):\(line)"
        }
    }

    public let items: [Item]
    /// The PR at a glance, made with the key lines (`PRKeyLinesSummaryCard.swift`): absent on an older answer.
    public let summary: Summary?
    public let context: Int
    /// Files too big to send, named so a short list isn't read as a whole one.
    public let leftOut: [String]
}

public struct PRRewrite: Decodable, Sendable {
    public let body: String
    public let hadTicket: Bool
}

/// A Worker job that failed, in its own words. `moved`: the PR has a newer commit than the one asked about.
public struct PRAIFailure: Decodable, Sendable {
    public let error: String
    public let moved: Bool?
}

/// The PR moved on past the commit the answer was asked for: read it again and ask at the newest.
struct PRAIHeadMoved: Error {}

extension Error {
    /// A failure that passes: no network, a slow or dropped request, the Worker briefly down or busy. Reading an AI
    /// answer changes nothing, so it is read again rather than shown.
    var isPassingAIFailure: Bool {
        if let error = self as? URLError {
            return [
                .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
            ].contains(error.code)
        }
        if let error = self as? PRWorkerError {
            return error == .unavailable || error == .limited
        }
        return false
    }
}

/// The key lines page of the navigator: what to look at first, and how much code the model read to choose.
struct PRKeyLinesList: View {
    private static let picks: [(title: String, context: Int)] = [
        ("Diff only", 0), ("±10", 10), ("±100", 100), ("Full", -1),
    ]

    let session: PRSession
    let document: DiffDocument
    @State private var customContext = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                contextPicker
                content
            }
            .padding(PRStyle.inset)
        }
        // The list's page, so each key line's card stands off it (DESIGN.md, A key line).
        .background(Color.groundList)
        .keyLinesReadToTheFoot()
    }

    private var contextPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                ForEach(Self.picks, id: \.context) { pick in
                    Button(pick.title) { session.setContextLines(pick.context) }
                        .buttonStyle(PRButtonStyle(session.contextLines == pick.context ? .primary : .secondary))
                        .lineLimit(1)
                        .accessibilityIdentifier("key-lines-context-\(pick.context)")
                }
                TextField("±", text: $customContext)
                    .font(.appFootnote.monospacedDigit())
                    .numericKeyboard()
                    .multilineTextAlignment(.center)
                    .frame(width: 48, height: PRStyle.controlHeight)
                    .background(
                        Color.groundFill,
                        in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous)
                    )
                    .onSubmit {
                        if let context = Int(customContext), context >= -1 {
                            session.setContextLines(context)
                        }
                    }
                    .accessibilityLabel("Lines of context")
                    .accessibilityIdentifier("key-lines-context-custom")
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var content: some View {
        switch session.keyLines {
        case .working where !session.model.network.isOnline:
            // The read goes on every few seconds and lands when the network is back; a spinner would say it is coming.
            Label("Key lines need a network. They show when it's back.", systemImage: AppIcon.offline.symbol)
                .font(.appCaption)
                .foregroundStyle(Color.toneWaiting)
                .accessibilityIdentifier("key-lines-offline")
        case .working:
            HStack(spacing: Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the change…")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(reason)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                Button("Try again") { Task { await session.loadKeyLines(retry: true) } }
                    .buttonStyle(PRButtonStyle(.secondary))
            }
        case let .ready(lines):
            VStack(alignment: .leading, spacing: Space.sm) {
                if let summary = lines.summary {
                    PRKeyLinesSummaryCard(summary: summary) { session.show($0) }
                }
                if !lines.items.isEmpty {
                    Text("\(session.reviewedKeyLineCount) of \(lines.items.count) reviewed")
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("key-lines-reviewed-count")
                }
                ForEach(lines.items) { item in
                    PRKeyLineRow(
                        item: item, isSelected: session.selectedKeyLine?.id == item.id,
                        isReviewed: session.isReviewed(item), show: { session.show(item) },
                        explain: session.offersAsk ? { session.explain(item, in: document) } : nil,
                        setReviewed: { session.setReviewed($0, item) }
                    )
                }
                if !lines.leftOut.isEmpty {
                    Text("Too big to read: \(lines.leftOut.joined(separator: ", "))")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension View {
    /// The last key line reads down to the tab bar. Without this the phone blurs the foot of the list for the height
    /// of the review bar under the panel, over the last line's words (Jai's picture, 2026-11-25).
    func keyLinesReadToTheFoot() -> some View {
        #if os(iOS)
            scrollEdgeEffectHidden(true, for: .bottom)
        #else
            self
        #endif
    }
}

/// One key line in the list, a card of its own: a heading line (its tick first, as a file's viewed mark is in Files;
/// its kind; Explain last, away from the tick), then where it is on a line to itself, cut in the middle so the file's
/// name and the line stay, then why it matters across the whole card. A tap anywhere but a control shows the line.
struct PRKeyLineRow: View {
    let item: PRKeyLines.Item
    let isSelected: Bool
    let isReviewed: Bool
    let show: () -> Void
    /// Nil where Ask AI is off: no Explain.
    let explain: (() -> Void)?
    let setReviewed: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        // A ticked line's words fade; its controls stay.
        let words = isReviewed ? PRStyle.doneOpacity : 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                PRKeyLineCheck(
                    isReviewed: isReviewed, toggle: { setReviewed(!isReviewed) },
                    identifier: "key-line-reviewed-\(item.id)"
                )
                StatusChip(text: item.kindTitle, tint: item.kindTint)
                    .opacity(words)
                    .frame(maxWidth: .infinity, minHeight: PRStyle.rowHeight, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(perform: show)
                    .accessibilityHidden(true)
                if let explain {
                    Button("Explain", systemImage: AppIcon.askAI.symbol, action: explain)
                        .labelStyle(.iconOnly)
                        .font(.appFootnote)
                        .foregroundStyle(Color.primary)
                        // A finger's width at least, and room beside the icon when the text is large.
                        .padding(.horizontal, Space.sm)
                        .frame(minWidth: PRStyle.rowHeight, minHeight: PRStyle.rowHeight)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Explain \(item.path):\(item.line)")
                        .accessibilityIdentifier("key-line-explain-\(item.id)")
                }
            }
            Button(action: show) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: "\(item.path):\(item.line)")
                        .font(.appCaption.monospaced())
                        .foregroundStyle(.secondary)
                        // One line, and in the largest text up to three: there one line holds a dozen letters.
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                    Text(item.why)
                        .font(.appFootnote)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], PRStyle.inset)
                .opacity(words)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.kindTitle), \(item.path):\(item.line), \(item.why)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("key-line-\(item.id)")
            .contextMenu {
                Button("Copy", systemImage: AppIcon.copy.symbol) { Pasteboard.copy(item.why) }
            }
        }
        .background(isSelected ? Color(platform: DiffStyle.selectedLine) : .clear)
        .prCard()
    }
}

enum PRNavigatorPage: String, CaseIterable, Identifiable {
    case files = "Files"
    case keyLines = "Key lines"

    var id: Self {
        self
    }
}

/// Finds a place in the diff: its files or its key lines, in the `sidePanel` over the code. Picking one closes it and
/// shows the place.
struct PRNavigator: View {
    @Bindable var session: PRSession
    let document: DiffDocument
    let files: [DiffRows.File]

    var body: some View {
        VStack(spacing: 0) {
            // Files alone when the Worker has no key lines and the host has no way to turn them on.
            if session.showsKeyLinesPage {
                Picker("Navigator", selection: $session.navigatorPage) {
                    ForEach(PRNavigatorPage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(PRStyle.inset)
                Divider()
            }
            switch session.shownNavigatorPage {
            case .files:
                PRFileList(files: files, viewed: session.viewedFiles) { session.show(file: $0) }
                Divider()
                filesFoot
            case .keyLines:
                if let hint = session.keyLinesHint {
                    PRKeyLinesOff(hint: hint)
                } else {
                    PRKeyLinesList(session: session, document: document)
                }
            }
        }
        .background(Color.groundCard)
        // The panel sets its own width: a wide screen's readable margins are not for it.
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }

    private var filesFoot: some View {
        let changedOnly = session.changedLinesOnly
        let wraps = session.longLines.wraps
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button("Changed lines only", systemImage: (changedOnly ? AppIcon.viewFilterOn : AppIcon.viewFilter).symbol) {
                session.setChangedLinesOnly(!changedOnly)
            }
            .buttonStyle(PRButtonStyle(.secondary))
            .accessibilityIdentifier("diff-changed-only")
            .accessibilityValue(changedOnly ? "on" : "off")
            Button("Wrap lines", systemImage: (wraps ? AppIcon.wrapLinesOn : AppIcon.wrapLines).symbol) {
                session.setWrapsLongLines(!wraps)
            }
            .buttonStyle(PRButtonStyle(.secondary))
            .accessibilityIdentifier("diff-wrap-lines")
            .accessibilityValue(wraps ? "on" : "off")
            Text(session.summary(document))
                .font(.appCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("diff-summary")
        }
        .padding(PRStyle.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Key lines page while key lines are off: the host's words for why, and its link that turns them on.
struct PRKeyLinesOff: View {
    let hint: PREmptyHint

    var body: some View {
        ContentUnavailableView {
            Label(hint.title, systemImage: AppIcon.keyLinesOff.symbol)
        } description: {
            Text(hint.message)
        } actions: {
            Link(hint.linkTitle, destination: hint.link)
                .buttonStyle(PRButtonStyle(.primary))
                .accessibilityIdentifier("key-lines-off")
        }
    }
}

extension PRKeyLines.Item {
    var kindTitle: String {
        switch kind {
        case "risk": "Risk"
        case "decision": "Decision"
        default: "Logic"
        }
    }

    var kindTint: Color {
        kind == "risk" ? .toneBad : .secondary
    }
}

/// A key line's tick: checked off as reviewed, or not yet. The circle a file's viewed mark is (`PRCheckCircle`), a
/// finger's width, first in the line's heading.
struct PRKeyLineCheck: View {
    let isReviewed: Bool
    let toggle: () -> Void
    let identifier: String

    var body: some View {
        Button(action: toggle) {
            PRCheckCircle(isOn: isReviewed)
                .contentTransition(.symbolEffect(.replace))
                // A finger's width at least, and room beside the circle when the text is large.
                .padding(.horizontal, Space.sm)
                .frame(minWidth: PRStyle.rowHeight, minHeight: PRStyle.rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reviewed")
        .accessibilityValue(isReviewed ? "checked" : "not checked")
        .accessibilityIdentifier(identifier)
    }
}

/// Under its line in the diff, while it's the key line being looked at: its kind and Close on top, why it matters
/// (long-press to copy), then Explain and Reviewed, so it's checked off where it's read.
struct PRKeyLineNote: View {
    let item: PRKeyLines.Item
    /// Read in the body, so the note follows a tick made in the list.
    let actions: DiffActions

    var body: some View {
        let reviewed = actions.isReviewed(item)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                StatusChip(text: item.kindTitle, tint: item.kindTint)
                Spacer(minLength: 0)
                Button("Close", systemImage: AppIcon.close.symbol, action: actions.closeNote)
                    .labelStyle(.iconOnly)
                    .font(.appFootnote)
                    .foregroundStyle(.secondary)
                    .frame(width: PRStyle.rowHeight, height: PRStyle.rowHeight)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("key-line-note-close")
            }
            Text(item.why)
                .font(.appFootnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(reviewed ? PRStyle.doneOpacity : 1)
                .textSelection(.enabled)
                .accessibilityIdentifier("key-line-note")
            // Their words while both fit; in the largest text their icons alone, words as their labels: there the words
            // broke a few letters to a line ("Ex- plai n", CI's picture, 2026-11-14), and one over the other ran the
            // note down under the stepper.
            ViewThatFits(in: .horizontal) {
                buttons(reviewed, iconOnly: false)
                buttons(reviewed, iconOnly: true)
            }
        }
        .padding([.leading, .bottom, .trailing], PRStyle.inset)
        .padding(.top, Space.xs)
        .prCard()
    }

    private func buttons(_ reviewed: Bool, iconOnly: Bool) -> some View {
        HStack(spacing: Space.sm) {
            if let explain = actions.explain {
                Button("Explain", systemImage: AppIcon.askAI.symbol) { explain(item) }
                    .buttonStyle(PRButtonStyle(.secondary, iconOnly: iconOnly))
                    .accessibilityIdentifier("key-line-note-explain")
            }
            Spacer(minLength: 0)
            Button(
                reviewed ? "Reviewed" : "Mark reviewed",
                systemImage: PRCheckCircle.symbol(isOn: reviewed)
            ) { actions.setReviewed(item, !reviewed) }
                .buttonStyle(PRButtonStyle(.secondary, iconOnly: iconOnly))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel("Reviewed")
                .accessibilityValue(reviewed ? "checked" : "not checked")
                .accessibilityIdentifier("key-line-note-reviewed")
        }
    }
}
