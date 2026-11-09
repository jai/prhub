import PRKitCore
import PRKitDesign
import SwiftUI

/// Where a reviewer should look in a PR, from the model through the Worker (`worker/src/ai.ts`). Every item is a line
/// the diff shows, so a tap always lands.
public struct PRKeyLines: Decodable, Sendable {
    public static let defaultContext = 100

    public struct Item: Decodable, Identifiable, Sendable {
        public let path: String
        public let line: Int
        public let side: String
        public let kind: String
        public let why: String

        public var id: String { "\(path):\(side):\(line)" }
    }

    public let items: [Item]
    public let context: Int
    /// Files too big to send, named so a short list isn't read as a whole one.
    public let leftOut: [String]
}

public struct PRRewrite: Decodable, Sendable {
    public let body: String
    public let hadTicket: Bool
}

/// A Worker job that failed, in its own words.
public struct PRAIFailure: Decodable, Sendable {
    public let error: String
}

/// The key lines page of the navigator: what to look at first, and how much code the model read to choose.
struct PRKeyLinesList: View {
    private static let picks: [(title: String, context: Int)] = [
        ("Diff only", 0), ("±10", 10), ("±100", 100), ("Full", -1),
    ]

    let session: PRSession
    @State private var customContext = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                contextPicker
                content
            }
            .padding(PRStyle.inset)
        }
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
            VStack(alignment: .leading, spacing: Space.xs) {
                if !lines.items.isEmpty {
                    Text("\(session.reviewedKeyLineCount) of \(lines.items.count) reviewed")
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("key-lines-reviewed-count")
                }
                ForEach(lines.items) { item in
                    let isSelected = session.selectedKeyLine?.id == item.id
                    HStack(alignment: .top, spacing: 0) {
                        Button { session.show(item) } label: { row(item) }
                            .buttonStyle(.plain)
                            .opacity(session.isReviewed(item) ? PRStyle.doneOpacity : 1)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityIdentifier("key-line-\(item.id)")
                        PRKeyLineCheck(item: item, session: session)
                    }
                    .background(
                        isSelected ? Color(platform: DiffStyle.selectedLine) : .clear,
                        in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous)
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

    private func row(_ item: PRKeyLines.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: item.symbol)
                .font(.appCaption)
                .foregroundStyle(item.kind == "risk" ? Color.toneBad : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: "\(item.path):\(item.line)")
                    .font(.appCaption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(item.why)
                    .font(.appFootnote)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.sm)
        .contentShape(.rect)
        .accessibilityValue(item.kind)
    }
}

enum PRNavigatorPage: String, CaseIterable, Identifiable {
    case files = "Files"
    case keyLines = "Key lines"

    var id: Self { self }
}

/// Finds a place in the diff: its files or its key lines, in the `sidePanel` over the code. Picking one closes it and
/// shows the place.
struct PRNavigator: View {
    @Bindable var session: PRSession
    let document: DiffDocument
    let files: [DiffRows.File]

    var body: some View {
        VStack(spacing: 0) {
            // Files alone when the Worker has no key lines (PRHub without a model key).
            if session.offersKeyLines {
                Picker("Navigator", selection: $session.navigatorPage) {
                    ForEach(PRNavigatorPage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(PRStyle.inset)
                Divider()
            }
            switch session.offersKeyLines ? session.navigatorPage : .files {
            case .files:
                PRFileList(files: files, viewed: session.viewedFiles) { session.show(file: $0) }
                Divider()
                filesFoot
            case .keyLines:
                PRKeyLinesList(session: session)
            }
        }
        .background(Color.groundCard)
        // The panel sets its own width: a wide screen's readable margins are not for it.
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }

    private var filesFoot: some View {
        let changedOnly = session.changedLinesOnly
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button("Changed lines only", systemImage: (changedOnly ? AppIcon.viewFilterOn : AppIcon.viewFilter).symbol) {
                session.setChangedLinesOnly(!changedOnly)
            }
            .buttonStyle(PRButtonStyle(.secondary))
            .accessibilityIdentifier("diff-changed-only")
            .accessibilityValue(changedOnly ? "on" : "off")
            Text(session.summary(document))
                .font(.appCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("diff-summary")
        }
        .padding(PRStyle.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PRKeyLines.Item {
    var symbol: String {
        switch kind {
        case "risk": "exclamationmark.triangle.fill"
        case "decision": "arrow.triangle.branch"
        default: "function"
        }
    }
}

/// A key line's tick: checked off as reviewed, or not yet. A finger's width, beside the line in the list or its note.
struct PRKeyLineCheck: View {
    let isReviewed: Bool
    let toggle: () -> Void
    let identifier: String

    init(isReviewed: Bool, identifier: String, toggle: @escaping () -> Void) {
        self.isReviewed = isReviewed
        self.identifier = identifier
        self.toggle = toggle
    }

    init(item: PRKeyLines.Item, session: PRSession) {
        isReviewed = session.isReviewed(item)
        identifier = "key-line-reviewed-\(item.id)"
        toggle = { [isReviewed] in session.setReviewed(!isReviewed, item) }
    }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: (isReviewed ? AppIcon.taskDone : AppIcon.taskOpen).symbol)
                .font(.appFootnote)
                .foregroundStyle(isReviewed ? Color.toneGood : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: PRStyle.rowHeight, height: PRStyle.rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reviewed")
        .accessibilityValue(isReviewed ? "checked" : "not checked")
        .accessibilityIdentifier(identifier)
    }
}

/// Under its line in the diff, while it's the key line being looked at, with its tick: check it off where it's read.
struct PRKeyLineNote: View {
    let item: PRKeyLines.Item
    /// Read in the body, so the note follows a tick made in the list (`DiffActions.isReviewed`).
    let isReviewed: (PRKeyLines.Item) -> Bool
    let setReviewed: (PRKeyLines.Item, Bool) -> Void
    let close: () -> Void

    var body: some View {
        let reviewed = isReviewed(item)
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: item.symbol)
                .font(.appCaption)
                .foregroundStyle(item.kind == "risk" ? Color.toneBad : Color.secondary)
            Text(item.why)
                .font(.appFootnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(reviewed ? PRStyle.doneOpacity : 1)
                .accessibilityIdentifier("key-line-note")
            PRKeyLineCheck(isReviewed: reviewed, identifier: "key-line-note-reviewed") {
                setReviewed(item, !reviewed)
            }
            Button("Close", systemImage: AppIcon.close.symbol, action: close)
                .labelStyle(.iconOnly)
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("key-line-note-close")
        }
        .padding(PRStyle.inset)
        .prCard()
    }
}
