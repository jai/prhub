#if os(macOS)
    import AppKit
    import PRKitCore
    import PRKitDesign
    import SwiftUI

    /// The phone's diff table, drawn by AppKit: one list of every file's header and rows. Long lines wrap in the window's
    /// width (`DiffRows.wraps`), a very long one as several rows; with wrapping off the list is wider than the window and
    /// code scrolls sideways. Threads, drafts and the comment box stay as wide as the window, held in view as the list moves.
    /// A click on a code line highlights it and opens the box under it.
    struct DiffTableView: NSViewRepresentable {
        let document: DiffDocument
        let rows: DiffRows
        let viewed: Set<String>
        let jump: DiffJump?
        let composing: Int?
        /// For the phone, whose diff runs under its bars.
        let topInset: CGFloat
        let font: DiffFont
        let onContent: () -> Void
        let actions: DiffActions

        func makeNSView(context _: Context) -> DiffTableContainer {
            DiffTableContainer(
                document: document, rows: rows, viewed: viewed, font: font, onContent: onContent, actions: actions
            )
        }

        func updateNSView(_ nsView: DiffTableContainer, context _: Context) {
            nsView.update(font: font)
            nsView.update(document: document, rows: rows)
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
        /// Taken with each new `rows`: a sync brings a new diff, and rows of it index lines this one may not have.
        private(set) var document: DiffDocument
        var rows: DiffRows
        var viewed: Set<String>
        private(set) var metrics: DiffMetrics
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
        /// Wrapped rows' heights, by line and piece, at `wrapWidth`: measured once each.
        private var wrapHeights: [WrapKey: CGFloat] = [:]
        private var wrapWidth: CGFloat = 0
        /// Measures a wrapped row as its label will draw it.
        private let wrapSizer = DiffLineView.wrappingLabel()

        private struct WrapKey: Hashable {
            let line: Int
            let piece: Int
        }

        init(
            document: DiffDocument, rows: DiffRows, viewed: Set<String>, font: DiffFont,
            onContent: @escaping () -> Void, actions: DiffActions
        ) {
            self.document = document
            self.rows = rows
            self.viewed = viewed
            self.actions = actions
            self.onContent = onContent
            metrics = DiffMetrics(font)
            super.init(frame: .zero)
            hasVerticalScroller = true
            hasHorizontalScroller = true
            autohidesScrollers = true
            // The code stops at its edges, as on the phone: a sideways rubber band would pull it off the window's edge.
            horizontalScrollElasticity = .none
            drawsBackground = false
            // Room to read the last line above the floating controls, as the phone's table leaves.
            automaticallyAdjustsContentInsets = false
            contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: DiffStyle.controlsClearance, right: 0)
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
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        // MARK: - Updates from the screen

        /// A new font from Settings, or a new text size: the code and headers redraw in it, where the reader was.
        func update(font: DiffFont) {
            let next = DiffMetrics(font)
            guard next.font != metrics.font || next.scale != metrics.scale else {
                return
            }
            metrics = next
            headers = [:]
            wrapHeights.removeAll()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                table.animator().reloadData()
            }
            tile()
        }

        /// After a post or a sync: the new threads, or the new diff, fade in, with the scroll position kept.
        func update(document: DiffDocument, rows: DiffRows) {
            guard rows.stamp != self.rows.stamp else {
                return
            }
            let rewraps = rows.wraps != self.rows.wraps
            self.document = document
            self.rows = rows
            wrapHeights.removeAll()
            if let composing, path(ofLine: composing) == nil {
                // The new diff may be shorter: the box's line is gone, so nothing may look it up before it closes.
                if !document.lines.indices.contains(composing) {
                    self.composing = nil
                }
                closeComposer()
            }
            let ids = Set(rows.threads.map(\.id) + rows.pending.map(\.id) + (rows.note.map { [$0.id] } ?? []))
            hosted = hosted.filter { ids.contains($0.key) }
            headers = [:]
            rebuild()
            table.reloadData()
            if rewraps {
                // Wrapped, there is nothing to the side: back to the left edge, and the list to the window's width.
                contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.minY))
                tile()
            }
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
            if let pending = jump.pending {
                reveal(pending: pending)
                return
            }
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

        /// A pending comment's card, whole: the least scroll that shows all of it, its foot above the room kept for the
        /// floating controls. Once the card has its new height: GitHub's reason and its buttons fold in, and a closed
        /// box folds away.
        private func reveal(pending id: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let place = rows.place(ofPending: id),
                      let index = items.firstIndex(of: .row(section: place.file, row: place.row))
                else {
                    return
                }
                let card = table.rect(ofRow: index)
                let seen = contentView.bounds
                if card.maxY > seen.maxY - DiffStyle.controlsClearance {
                    scrollTable(toY: min(card.minY, card.maxY + DiffStyle.controlsClearance - seen.height))
                } else if card.minY < seen.minY {
                    scrollTable(toY: card.minY)
                }
            }
        }

        func scrollTable(toY top: CGFloat) {
            // As far as the last row's foot above the room kept for the floating controls.
            let end = max(table.bounds.height + contentInsets.bottom - contentView.bounds.height, 0)
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
            let codeWidth = CGFloat(DiffDocument.columns + 2) * metrics.columnWidth
            let width = rows.wraps ? contentView.bounds.width
                : max(contentView.bounds.width, codeWidth + metrics.gutterWidth(digits: document.lineNumberDigits))
            if let column = table.tableColumns.first, column.width != width {
                column.width = width
            }
            if rows.wraps, wrapWidth != width {
                // A new width: wrapped lines break elsewhere, so every row's height is asked for again.
                wrapWidth = width
                wrapHeights.removeAll()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
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

        /// The code's room when lines wrap; nil when they scroll, or before the list has a width.
        var wrap: DiffWrap? {
            guard rows.wraps, wrapWidth > 0 else {
                return nil
            }
            return DiffWrap(
                metrics: metrics, width: metrics.codeWidth(inRow: wrapWidth, digits: document.lineNumberDigits)
            )
        }

        /// A code row's height: the fixed one unless the piece wraps, and then what its label measures, kept.
        private func codeRowHeight(line: Int, piece: Int) -> CGFloat {
            guard let wrap, !wrap.isOneRow(line: line, piece: piece, of: document) else {
                return metrics.rowHeight
            }
            let key = WrapKey(line: line, piece: piece)
            if let height = wrapHeights[key] {
                return height
            }
            let text = wrap.text(line: line, piece: piece, of: document)
            wrapSizer.lineBreakMode = DiffWrap.lineBreakMode(of: text)
            wrapSizer.attributedStringValue = text
            let room = NSRect(x: 0, y: 0, width: wrap.width, height: DiffWrap.unbounded)
            let whole = wrap.height(fitting: wrapSizer.cell?.cellSize(forBounds: room).height ?? 0)
            let height = wrap.height(whole, isCut: rows.cut.contains(line))
            wrapHeights[key] = height
            return height
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
            guard document.lines.indices.contains(index), rows.files.indices.contains(document.lines[index].file) else {
                return nil
            }
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

        func numberOfRows(in _: NSTableView) -> Int {
            items.count
        }

        func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = items[row] {
                return true
            }
            return false
        }

        func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
            false
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch items[row] {
            case .header:
                return metrics.fileHeaderHeight
            case let .row(section, index):
                switch self.row(section: section, row: index) {
                case let .line(line): return codeRowHeight(line: line, piece: 0)
                case let .piece(line, piece): return codeRowHeight(line: line, piece: piece)
                case .rest, .less: return metrics.rowHeight + Space.sm
                case .thread, .draft, .note: break
                }
                let height = hostedID(section: section, row: index).flatMap { hosted[$0]?.height }
                    ?? hostedRow(section: section, row: index)?.height ?? 0
                return height + DiffStyle.threadInset * 2
            }
        }

        func tableView(_: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = DiffRowView()
            if case let .row(section, index) = items[row] {
                switch self.row(section: section, row: index) {
                case let .line(line), let .piece(line, _): rowView.fill = fill(forLine: line)
                case let .rest(line), let .less(line): rowView.fill = DiffStyle.background(document.lines[line].kind)
                case .thread, .draft, .note: break
                }
            }
            return rowView
        }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            switch items[row] {
            case let .header(section):
                return headerView(section)
            case let .row(section, index):
                switch self.row(section: section, row: index) {
                case let .line(line): return lineView(line)
                case let .piece(line, piece): return lineView(line, piece: piece)
                case let .rest(line): return restView(line)
                case let .less(line): return restView(line, isLess: true)
                case .thread, .draft, .note: break
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
