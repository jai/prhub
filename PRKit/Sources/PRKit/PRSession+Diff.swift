import PRKitCore
import PRKitDesign
import SwiftUI

/// What the diff page asks of its session: stepping through key lines, what it says about itself, and viewed marks.
extension PRSession {
    var keyLineItems: [PRKeyLines.Item] {
        if offersKeyLines, case let .ready(lines) = keyLines {
            return lines.items
        }
        return []
    }

    /// The Worker's AI features, as `GET /device/config` has them in PRHub; all three in Jai's build.
    var offersKeyLines: Bool { model.configuration.isOn(.keyLines) }

    /// Why key lines are off and how to turn them on, while they are (`PRKitConfiguration.keyLinesHint`).
    var keyLinesHint: PREmptyHint? { offersKeyLines ? nil : model.configuration.keyLinesHint }
    var offersAsk: Bool { model.configuration.isOn(.askAI) }
    var offersRewrite: Bool { model.configuration.isOn(.rewrite) }

    /// Previous or next key line not yet checked off, going round; every one once all are. With none selected, next
    /// is the first and previous the last.
    func stepKeyLine(by step: Int) {
        let items = keyLineItems
        let open = items.filter { !isReviewed($0) }
        let stops = open.isEmpty ? items : open
        guard !stops.isEmpty else {
            return
        }
        guard let current = items.firstIndex(where: { $0.id == selectedKeyLine?.id }) else {
            show(step > 0 ? stops[0] : stops[stops.count - 1])
            return
        }
        // From the one on show, which may itself be checked off, to the next stop in the list's order.
        for offset in 1...items.count {
            let item = items[((current + step * offset) % items.count + items.count) % items.count]
            if stops.contains(where: { $0.id == item.id }) {
                show(item)
                return
            }
        }
    }

    /// How the diff got here, for the panel's foot and the log.
    func summary(_ document: DiffDocument) -> String {
        let scrollable = timer.milliseconds.map { "\(Int($0.rounded())) ms to scrollable" } ?? "…"
        let size = document.data.count.formatted(.byteCount(style: .file))
        return "\(scrollable) · \(document.lines.count) lines · \(size) · \(isPreloaded ? "preloaded" : "live")"
    }

    func setViewed(_ isViewed: Bool, path: String) {
        guard let id = content?.detail.id else {
            return
        }
        viewedFiles.formSymmetricDifference([path])
        notice = nil
        // Jai's `-UXFixtures` samples: nothing is marked anywhere but here.
        if model.samples?.answersOnPhone == false {
            return
        }
        Task {
            do {
                // Posted or saved to go: the file stays marked either way.
                _ = try await model.write(.viewed(pullRequest: id, path: path, viewed: isViewed), to: ref)
            } catch {
                viewedFiles.formSymmetricDifference([path])
                notice = .failed(error.localizedDescription)
            }
        }
    }
}

/// Where the diff's panel of files and key lines goes: over the diff, which dims under it, or beside it as a column when
/// the screen is wide enough for both.
enum PRPanelPlacement: Equatable {
    case overlay, column

    /// A regular width with room for the column and a diff of `PanelStyle.diffWidth`.
    static func fitting(width: CGFloat, isRegularWidth: Bool) -> PRPanelPlacement {
        isRegularWidth && width >= PanelStyle.columnWidth + PanelStyle.diffWidth ? .column : .overlay
    }
}

/// The diff's screen: its arrival, its panel, and stepping file to file from the keyboard.
extension PRSession {
    /// The diff came on screen. Its timer counts from here when the reader came from the description; a diff opened
    /// straight from a row or link counts from that tap.
    func diffAppeared() {
        isDiffOnScreen = true
        barsHidden = false
        if !hasShownDiff {
            hasShownDiff = true
            if hasShownDescription {
                timer.restart()
            }
        }
        if opensPanelOnArrival {
            opensPanelOnArrival = false
            // A line's half-written comment stays in view; the panel waits for its button.
            if composingLine == nil {
                openPanel(on: .keyLines)
            }
        }
    }

    func diffDisappeared() {
        isDiffOnScreen = false
        barsHidden = false
    }

    var isPanelOpen: Bool {
        switch panelPlacement {
        case .overlay: isShowingNavigator
        case .column: !isPanelColumnHidden
        }
    }

    func openPanel(on page: PRNavigatorPage? = nil) {
        withAnimation(AppMotion.fold) {
            if let page {
                navigatorPage = page
            }
            switch panelPlacement {
            case .overlay: isShowingNavigator = true
            case .column: isPanelColumnHidden = false
            }
        }
    }

    /// The panel button and its shortcut: open it, or put it away.
    func togglePanel() {
        guard isPanelOpen else {
            openPanel()
            return
        }
        withAnimation(AppMotion.fold) {
            switch panelPlacement {
            case .overlay: isShowingNavigator = false
            case .column: isPanelColumnHidden = true
            }
        }
    }

    /// The width changed. Wider, the column shows; narrower, the panel waits for its button rather than cover the code.
    func placePanel(_ placement: PRPanelPlacement) {
        guard placement != panelPlacement else {
            return
        }
        panelPlacement = placement
        isShowingNavigator = false
        if placement == .column {
            isPanelColumnHidden = false
        }
    }

    /// The next or previous file from the one at the top of the screen, going round.
    func stepFile(by step: Int, in files: [DiffRows.File]) {
        guard !files.isEmpty else {
            return
        }
        let next = topFile.map { ($0 + step + files.count) % files.count } ?? (step > 0 ? 0 : files.count - 1)
        topFile = next
        show(file: files[next].path)
    }

    /// Viewed on or off for the file at the top of the screen.
    func toggleViewedOnTopFile(in files: [DiffRows.File]) {
        guard let index = topFile ?? files.indices.first, files.indices.contains(index) else {
            return
        }
        let path = files[index].path
        setViewed(!viewedFiles.contains(path), path: path)
    }
}

/// A hardware keyboard's way round the diff on show (an iPad's, a Mac's): the next and previous file, Viewed on the file
/// at the top, and the panel. Each is a button, so the system lists it under ⌘. It sits on the PRs tab, above both of a
/// wide screen's columns, so it answers wherever the focus is.
struct PRDiffShortcuts: View {
    let session: PRSession

    var body: some View {
        let files = session.content.flatMap { content -> [DiffRows.File]? in
            guard case let .document(_, rows) = content.diff else {
                return nil
            }
            return rows.files
        } ?? []
        Group {
            Button("Next file") { session.stepFile(by: 1, in: files) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous file") { session.stepFile(by: -1, in: files) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Toggle viewed") { session.toggleViewedOnTopFile(in: files) }
                .keyboardShortcut("v", modifiers: [.command, .control])
            Button(session.isPanelOpen ? "Close panel" : "Open panel") { session.togglePanel() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
