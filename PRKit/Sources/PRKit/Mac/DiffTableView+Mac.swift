#if os(macOS)
import PRKitCore
import PRKitDesign
import AppKit
import SwiftUI

/// The phone's diff table, drawn by AppKit: one list of every file's header and rows, wider than the window so code
/// scrolls sideways. Threads, drafts and the comment box stay as wide as the window, held in view as the list moves.
/// A click on a code line highlights it and opens the box under it.
struct DiffTableView: NSViewRepresentable {
    let document: DiffDocument
    let rows: DiffRows
    let viewed: Set<String>
    let jump: DiffJump?
    let composing: Int?
    /// For the phone, whose diff runs under its bars.
    let topInset: CGFloat
    let onContent: () -> Void
    let actions: DiffActions

    func makeNSView(context: Context) -> DiffTableContainer {
        DiffTableContainer(document: document, rows: rows, viewed: viewed, onContent: onContent, actions: actions)
    }

    func updateNSView(_ nsView: DiffTableContainer, context: Context) {
        nsView.update(rows: rows)
        nsView.update(viewed: viewed)
        nsView.update(composing: composing)
        nsView.update(jump: jump)
    }
}

final class DiffTableContainer: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum Item: Equatable {
        case header(Int)
        /// A row of a file as drawn: the comment box counts as one.
        case row(section: Int, row: Int)
    }

    let table = ClickableTableView()
    let document: DiffDocument
    var rows: DiffRows
    var viewed: Set<String>
    private var lastJump: DiffJump?
    let actions: DiffActions
    private var onContent: (() -> Void)?
    /// The line of the document being commented on.
    var composing: Int?
    var items: [Item] = []
    /// Threads, drafts and the box, by id: each keeps its SwiftUI state, a half-typed reply included, while it lives.
    var hosted: [String: HostedRow] = [:]
    /// The window's width less the margins, which every hosted row is laid out to.
    let hostedWidth = HostedWidth()
    /// By file, so a fold or a viewed mark turns the one on screen.
    var headers: [Int: DiffFileHeaderView] = [:]

    init(
        document: DiffDocument, rows: DiffRows, viewed: Set<String>, onContent: @escaping () -> Void,
        actions: DiffActions
    ) {
        self.document = document
        self.rows = rows
        self.viewed = viewed
        self.actions = actions
        self.onContent = onContent
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        let column = NSTableColumn(identifier: .init("diff"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.floatsGroupRows = true
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] in self?.clicked($0) }
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView
        )
        rebuild()
        table.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a storyboard")
    }

    // MARK: - Updates from the screen

    /// After a post: the new threads fade in, with the scroll position kept.
    func update(rows: DiffRows) {
        guard rows.stamp != self.rows.stamp else {
            return
        }
        self.rows = rows
        if let composing, path(ofLine: composing) == nil {
            closeComposer()
        }
        let ids = Set(rows.threads.map(\.id) + rows.drafts.map(\.id.uuidString) + (rows.note.map { [$0.id] } ?? []))
        hosted = hosted.filter { ids.contains($0.key) }
        headers = [:]
        rebuild()
        table.reloadData()
    }

    /// A file marked viewed folds, and one unmarked opens, wherever the change came from.
    func update(viewed next: Set<String>) {
        for path in next.symmetricDifference(viewed) {
            guard let section = rows.files.firstIndex(where: { $0.path == path }) else {
                viewed.formSymmetricDifference([path])
                continue
            }
            let isNowViewed = next.contains(path)
            guard !(composingSection == section && composerHasText) else {
                viewed.formSymmetricDifference([path])
                continue
            }
            if composingSection == section {
                closeComposer()
            }
            refold(section) {
                viewed.formSymmetricDifference([path])
                if isCollapsed(section) != isNowViewed {
                    actions.folds.toggle(rows.files[section].foldID)
                }
            }
        }
    }

    func update(jump: DiffJump?) {
        guard let jump, jump != lastJump else {
            return
        }
        lastJump = jump
        guard let section = rows.files.firstIndex(where: { $0.path == jump.path }) else {
            return
        }
        contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.minY))
        if let target = lineToShow(jump, in: section), let index = items.firstIndex(of: target) {
            let middle = table.rect(ofRow: index).midY - contentView.bounds.height / 2
            scrollTable(toY: middle)
            return
        }
        if let header = items.firstIndex(of: .header(section)) {
            scrollTable(toY: table.rect(ofRow: header).minY)
        }
    }

    func scrollTable(toY top: CGFloat) {
        let end = max(table.bounds.height - contentView.bounds.height, 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(top, 0), end)))
        }
        reflectScrolledClipView(contentView)
    }

    /// Yellow for the line being commented on and the key line being looked at.
    func fill(forLine line: Int) -> NSColor {
        line == composing || line == rows.noteLine
            ? DiffStyle.selectedLine : DiffStyle.background(document.lines[line].kind)
    }

    // MARK: - Layout

    /// A scroll view lays its parts out here, not in `layout()`: on every resize of the window.
    override func tile() {
        super.tile()
        let columnWidth = ("M" as NSString).size(withAttributes: [.font: DiffStyle.font]).width
        let width = max(contentView.bounds.width, CGFloat(DiffDocument.columns + 2) * columnWidth)
        if let column = table.tableColumns.first, column.width != width {
            column.width = width
        }
        let rowWidth = max(contentView.bounds.width - DiffStyle.threadInset * 2, 200)
        if hostedWidth.value != rowWidth {
            hostedWidth.value = rowWidth
            remeasureAll()
        }
        pinToVisibleWidth()
        if let onContent, table.numberOfRows > 0 {
            self.onContent = nil
            onContent()
        }
    }

    @objc private func scrolled() {
        pinToVisibleWidth()
    }

    /// Headers and hosted rows sit where the window is, in the list's sideways scroll.
    private func pinToVisibleWidth() {
        let visible = contentView.bounds
        let views = table.subviews + contentView.subviews.filter { $0 !== table }
        for rowView in views {
            for case let pinned as PinnedToWindow in rowView.subviews {
                pinned.pin(offsetX: visible.minX, width: visible.width)
            }
        }
    }

    // MARK: - Rows

    /// Every file's header, then its rows when it's open.
    func rebuild() {
        items = rows.files.indices.flatMap { section -> [Item] in
            [.header(section)] + (0 ..< rowCount(section)).map { .row(section: section, row: $0) }
        }
    }

    private func rowCount(_ section: Int) -> Int {
        guard !isCollapsed(section) else {
            return 0
        }
        return rows.files[section].rows.count
    }

    var composingSection: Int? {
        composing.map { document.lines[$0].file }
    }

    var composerHasText: Bool {
        composing.map { !actions.text(document.lines[$0]).wrappedValue.allSatisfy(\.isWhitespace) } ?? false
    }

    func path(ofLine index: Int) -> IndexPath? {
        let section = document.lines[index].file
        return rows.files[section].rows.firstIndex(of: .line(index)).map { IndexPath(item: $0, section: section) }
    }

    /// A viewed file starts folded, as on GitHub, and a click on its header still opens it.
    func isCollapsed(_ section: Int) -> Bool {
        let file = rows.files[section]
        return viewed.contains(file.path) != actions.folds.isFlipped(file.foldID)
    }

    func row(section: Int, row: Int) -> DiffRows.Row {
        rows.files[section].rows[row]
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header:
            return DiffStyle.fileHeaderHeight
        case let .row(section, index):
            if case .line = self.row(section: section, row: index) {
                return DiffStyle.rowHeight
            }
            let height = hostedID(section: section, row: index).flatMap { hosted[$0]?.height }
                ?? hostedRow(section: section, row: index)?.height ?? 0
            return height + DiffStyle.threadInset * 2
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = DiffRowView()
        if case let .row(section, index) = items[row], case let .line(line) = self.row(section: section, row: index) {
            rowView.fill = fill(forLine: line)
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case let .header(section):
            return headerView(section)
        case let .row(section, index):
            if case let .line(line) = self.row(section: section, row: index) {
                return lineView(line)
            }
            return hostedRow(section: section, row: index).map { host in
                let cell = HostedCell(host: host)
                cell.pin(offsetX: contentView.bounds.minX, width: contentView.bounds.width)
                return cell
            }
        }
    }
}

/// Holds one row's background: a code line's colour, or yellow while it's being commented on.
/// Says which row a click landed on. The table's own action only comes for rows it may select, and none may be.
final class ClickableTableView: NSTableView {
    var onClick: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        onClick(clicked)
    }
}

/// Its own colour, not `backgroundColor`, which the table sets back to its own on every row it adds.
final class DiffRowView: NSTableRowView {
    var fill: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

/// A view laid out against the window, not the list: the list is wider than the window.
protocol PinnedToWindow: NSView {
    func pin(offsetX: CGFloat, width: CGFloat)
}
#endif
