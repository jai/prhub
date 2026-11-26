#if os(macOS)
    import AppKit
    import PRKitCore
    import PRKitDesign
    import SwiftUI

    /// A thread, a draft or the comment box. SwiftUI says when its height changes, and the list moves the rows under it.
    final class HostedRow: NSHostingView<AnyView> {
        var onResize: () -> Void = {}
        var height: CGFloat = 0

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onResize() }
        }

        /// Its height at `width`, the window's less the margins.
        func measure(width: CGFloat) -> CGFloat {
            setFrameSize(NSSize(width: width, height: frame.height))
            return ceil(fittingSize.height)
        }
    }

    @Observable final class HostedWidth {
        var value: CGFloat = 320
    }

    /// Lays a hosted row out to the window's width, which changes as the window does.
    struct HostedFrame<Content: View>: View {
        let width: HostedWidth
        let content: Content

        var body: some View {
            content
                .frame(width: width.value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    final class HostedCell: NSView, PinnedToWindow {
        let host: HostedRow

        init(host: HostedRow) {
            self.host = host
            super.init(frame: .zero)
            host.removeFromSuperview()
            addSubview(host)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        func pin(offsetX: CGFloat, width: CGFloat) {
            let inset = DiffStyle.threadInset
            host.frame = NSRect(x: offsetX + inset, y: inset, width: width - inset * 2, height: host.height)
        }
    }

    final class DiffLineView: NSTableCellView {
        static let identifier = NSUserInterfaceItemIdentifier("line")
        let label = NSTextField(labelWithString: "")
        let oldNumber = NSTextField(labelWithString: "")
        let newNumber = NSTextField(labelWithString: "")
        private var numberWidth: CGFloat = 0
        /// The first row's height where the code wraps over several: the numbers sit beside that row. Nil on one row.
        private var firstRowHeight: CGFloat?

        /// A label that wraps as a wrapped row's does: the list measures with one of these.
        static func wrappingLabel() -> NSTextField {
            let label = NSTextField(labelWithString: "")
            wrap(label, true)
            return label
        }

        private static func wrap(_ label: NSTextField, _ wraps: Bool) {
            label.usesSingleLineMode = !wraps
            label.maximumNumberOfLines = wraps ? 0 : 1
            label.lineBreakMode = wraps ? .byWordWrapping : .byClipping
            label.cell?.wraps = wraps
            label.cell?.isScrollable = false
            label.cell?.truncatesLastVisibleLine = false
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            identifier = Self.identifier
            label.lineBreakMode = .byClipping
            label.cell?.truncatesLastVisibleLine = false
            for number in [oldNumber, newNumber] {
                number.alignment = .right
                number.textColor = .secondaryLabelColor
                number.lineBreakMode = .byClipping
                addSubview(number)
            }
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        func configure(line: DiffDocument.Line, text: String, metrics: DiffMetrics, digits: Int) {
            Self.wrap(label, false)
            firstRowHeight = nil
            for field in [label, oldNumber, newNumber] {
                field.font = metrics.code
            }
            label.stringValue = text
            setNumbers(line, metrics: metrics, digits: digits)
        }

        /// A piece of a line wrapped in the row's width, as `DiffWrap.text` made it. Only a line's first piece has its
        /// numbers. `rows` is how many of its rows are drawn, for a line shown cut; 0 is all of them.
        func configure(
            line: DiffDocument.Line, wrapped text: NSAttributedString, isFirstPiece: Bool, rows: Int = 0,
            metrics: DiffMetrics, digits: Int
        ) {
            Self.wrap(label, true)
            label.maximumNumberOfLines = rows
            firstRowHeight = metrics.rowHeight
            for field in [label, oldNumber, newNumber] {
                field.font = metrics.code
            }
            label.lineBreakMode = DiffWrap.lineBreakMode(of: text)
            label.attributedStringValue = text
            setNumbers(isFirstPiece ? line : nil, metrics: metrics, digits: digits)
        }

        private func setNumbers(_ line: DiffDocument.Line?, metrics: DiffMetrics, digits: Int) {
            let line = line ?? DiffDocument.Line(start: 0, length: 0, kind: .meta, file: 0, oldLine: 0, newLine: 0)
            oldNumber.stringValue = line.oldLine > 0 ? String(line.oldLine) : ""
            newNumber.stringValue = line.newLine > 0 ? String(line.newLine) : ""
            oldNumber.setAccessibilityLabel(line.oldLine > 0 ? "Old line \(line.oldLine)" : nil)
            newNumber.setAccessibilityLabel(line.newLine > 0 ? "New line \(line.newLine)" : nil)
            numberWidth = metrics.lineNumberWidth(digits: digits)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let step = numberWidth + DiffStyle.lineNumberGap
            let inset = DiffStyle.lineInset
            // Beside the first row of a wrapped line, which is the top one: AppKit counts up from the bottom.
            let numberHeight = min(firstRowHeight ?? bounds.height, bounds.height)
            oldNumber.frame = NSRect(
                x: inset, y: bounds.height - numberHeight, width: numberWidth, height: numberHeight
            )
            newNumber.frame = oldNumber.frame.offsetBy(dx: step, dy: 0)
            let codeX = inset + step * 2
            label.frame = NSRect(x: codeX, y: 0, width: max(0, bounds.width - codeX - inset), height: bounds.height)
        }
    }

    /// "Show full line": a link the width of the code, under the pieces shown of a very long line. The list's click
    /// opens the line.
    final class DiffRestView: NSView {
        private let title: NSTextField
        private let codeX: CGFloat

        init(title text: String, metrics: DiffMetrics, digits: Int) {
            title = NSTextField(labelWithString: text)
            codeX = DiffStyle.lineInset + metrics.gutterWidth(digits: digits)
            super.init(frame: .zero)
            title.font = metrics.code
            title.textColor = .controlAccentColor
            title.lineBreakMode = .byTruncatingMiddle
            title.setAccessibilityRole(.button)
            addSubview(title)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        override func layout() {
            super.layout()
            let height = title.fittingSize.height
            title.frame = NSRect(
                x: codeX, y: (bounds.height - height) / 2, width: max(0, bounds.width - codeX - DiffStyle.lineInset),
                height: height
            )
        }
    }

    /// A file's header: it sticks to the top while its file scrolls, a click folds it, and the circle marks it viewed.
    final class DiffFileHeaderView: NSView, PinnedToWindow {
        private let bar = NSView()
        private let chevron = NSImageView()
        private let path = NSTextField(labelWithString: "")
        private let change = NSTextField(labelWithString: "")
        private let viewed = NSButton()
        private var isViewed = false
        private let metrics: DiffMetrics
        /// The width the path's size was fitted to: fitted again only when it changes, not on every sideways scroll.
        private var fittedWidth: CGFloat?
        var onTap: () -> Void = {}
        var onViewed: (Bool) -> Void = { _ in }

        init(_ file: DiffRows.File, section: Int, isCollapsed: Bool, isViewed: Bool, metrics: DiffMetrics) {
            self.metrics = metrics
            super.init(frame: .zero)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: metrics.chevronSymbolSize, weight: .semibold))
            chevron.contentTintColor = .secondaryLabelColor
            path.font = metrics.headerPath
            path.lineBreakMode = .byTruncatingHead
            path.stringValue = file.path
            path.setAccessibilityIdentifier("file-header-\(section)")
            let text = NSMutableAttributedString(
                string: "+\(file.change.added)", attributes: [.foregroundColor: NSColor.systemGreen]
            )
            text.append(NSAttributedString(
                string: " −\(file.change.removed)", attributes: [.foregroundColor: NSColor.systemRed]
            ))
            text.addAttribute(
                .font, value: metrics.headerChange,
                range: NSRange(location: 0, length: text.length)
            )
            change.attributedStringValue = text
            change.alignment = .right
            viewed.isBordered = false
            viewed.target = self
            viewed.action = #selector(viewedClicked)
            viewed.setAccessibilityIdentifier("file-viewed-\(section)")
            for view in [chevron, path, change, viewed] {
                bar.addSubview(view)
            }
            addSubview(bar)
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
            setViewed(isViewed)
            setCollapsed(isCollapsed)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        func setViewed(_ isViewed: Bool) {
            self.isViewed = isViewed
            viewed.image = NSImage(
                systemSymbolName: isViewed ? "checkmark.circle.fill" : "circle", accessibilityDescription: "Viewed"
            )?.withSymbolConfiguration(.init(pointSize: metrics.viewedSymbolSize, weight: .regular))
            viewed.contentTintColor = isViewed ? .systemGreen : .secondaryLabelColor
            viewed.setAccessibilityValue(isViewed ? "on" : "off")
        }

        func setCollapsed(_ isCollapsed: Bool) {
            path.setAccessibilityValue(isCollapsed ? "collapsed" : "open")
            let angle: CGFloat = isCollapsed ? 90 : 0
            guard chevron.frameCenterRotation != angle else {
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                chevron.animator().frameCenterRotation = angle
            }
        }

        func pin(offsetX: CGFloat, width: CGFloat) {
            let height = metrics.fileHeaderHeight
            bar.frame = NSRect(x: offsetX, y: 0, width: width, height: height)
            let inset = Space.sm
            let chevronWidth = metrics.chevronSymbolSize + Space.xs
            let changeWidth = change.fittingSize.width
            let rotation = chevron.frameCenterRotation
            chevron.frameCenterRotation = 0
            chevron.frame = NSRect(x: inset, y: 0, width: chevronWidth, height: height)
            chevron.frameCenterRotation = rotation
            viewed.frame = NSRect(
                x: width - metrics.viewedTarget, y: 0, width: metrics.viewedTarget, height: height
            )
            let changeHeight = change.fittingSize.height
            change.frame = NSRect(
                x: viewed.frame.minX - changeWidth, y: (height - changeHeight) / 2, width: changeWidth, height: changeHeight
            )
            // Not from the chevron's frame: turned, its frame is the box around it, wider than it stands.
            let pathX = inset + chevronWidth + Space.sm
            let pathWidth = change.frame.minX - pathX - Space.sm
            if fittedWidth != pathWidth {
                fittedWidth = pathWidth
                path.font = metrics.headerPath(fitting: path.stringValue, in: pathWidth)
            }
            let pathHeight = path.fittingSize.height
            path.frame = NSRect(x: pathX, y: (height - pathHeight) / 2, width: pathWidth, height: pathHeight)
        }

        @objc private func clicked() {
            onTap()
        }

        @objc private func viewedClicked() {
            onViewed(!isViewed)
        }
    }

    extension DiffTableContainer {
        /// A line of code, or one piece of a long one where lines wrap: the line's numbers are beside its first.
        func lineView(_ index: Int, piece: Int = 0) -> NSView {
            let reused = table.makeView(withIdentifier: DiffLineView.identifier, owner: nil) as? DiffLineView
            let view = reused ?? DiffLineView()
            let line = document.lines[index]
            if rows.wraps {
                // Before the list has a width a row is asked for by a test alone, and nothing is narrow enough to wrap.
                let wrap = wrap ?? DiffWrap(metrics: metrics, width: DiffWrap.unbounded)
                view.configure(
                    line: line, wrapped: wrap.text(line: index, piece: piece, of: document), isFirstPiece: piece == 0,
                    rows: rows.cut.contains(index) ? DiffWrap.shownRows : 0, metrics: metrics,
                    digits: document.lineNumberDigits
                )
            } else {
                let text = document.text(of: line, limit: DiffDocument.columns)
                view.configure(
                    line: line, text: document.isClipped(line) ? "\(text)⋯" : text,
                    metrics: metrics, digits: document.lineNumberDigits
                )
            }
            view.setAccessibilityIdentifier(piece == 0 ? "diff-line-\(index)" : "diff-line-\(index)-piece-\(piece)")
            return view
        }

        /// "Show full line", under the start of a very long line; "Show less" under its end.
        func restView(_ index: Int, isLess: Bool = false) -> NSView {
            let view = DiffRestView(
                title: isLess ? DiffWrap.lessTitle : DiffWrap.restTitle(document.lines[index]), metrics: metrics, digits: document.lineNumberDigits
            )
            view.setAccessibilityIdentifier("diff-line-\(index)-\(isLess ? "less" : "rest")")
            return view
        }

        func headerView(_ section: Int) -> NSView {
            if let header = headers[section] {
                header.pin(offsetX: contentView.bounds.minX, width: contentView.bounds.width)
                return header
            }
            let file = rows.files[section]
            let header = DiffFileHeaderView(
                file, section: section, isCollapsed: isCollapsed(section), isViewed: viewed.contains(file.path),
                metrics: metrics
            )
            headers[section] = header
            header.onTap = { [weak self] in self?.toggleFile(section) }
            header.onViewed = { [weak self] in self?.actions.setViewed($0, file.path) }
            header.pin(offsetX: contentView.bounds.minX, width: contentView.bounds.width)
            return header
        }

        func hostedID(section: Int, row: Int) -> String? {
            switch self.row(section: section, row: row) {
            case .line, .piece, .rest, .less: nil
            case let .thread(index): rows.threads[index].id
            case let .draft(index): rows.pending[index].id
            case .note: rows.note?.id
            }
        }

        /// The host for a thread, a draft or the box, kept by id and given its current content.
        func hostedRow(section: Int, row: Int) -> HostedRow? {
            switch self.row(section: section, row: row) {
            case .line, .piece, .rest, .less:
                return nil
            case let .thread(index):
                let thread = rows.threads[index]
                let isCollapsed = thread.isResolved != actions.folds.isFlipped(thread.id)
                return host(thread.id) {
                    PRThreadCard(
                        thread: thread, isCollapsed: isCollapsed, replyText: actions.replyText(thread),
                        onToggle: { [weak self] in self?.toggleThread(thread.id) },
                        reply: { [weak self] text in try await self?.actions.reply(thread, text) },
                        setResolved: { [weak self] in try await self?.actions.setResolved(thread, $0) }
                    )
                }
            case let .draft(index):
                let comment = rows.pending[index]
                return host(comment.id) {
                    PRPendingCard(comment: comment, actions: actions.pending)
                }
            case .note:
                guard let note = rows.note else {
                    return nil
                }
                return host(note.id) {
                    PRKeyLineNote(item: note, actions: actions)
                }
            }
        }

        private func host(_ id: String, @ViewBuilder content: () -> some View) -> HostedRow {
            let view = AnyView(HostedFrame(width: hostedWidth, content: content().environment(\.openURL, actions.openURL)))
            if let existing = hosted[id] {
                existing.rootView = view
                return existing
            }
            let host = HostedRow(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            host.onResize = { [weak self] in self?.remeasure(id) }
            hosted[id] = host
            host.height = host.measure(width: hostedWidth.value)
            return host
        }

        /// A thread opened, a reply grew: the rows under it move.
        func remeasure(_ id: String) {
            guard let host = hosted[id] else {
                return
            }
            let height = host.measure(width: hostedWidth.value)
            guard height != host.height else {
                return
            }
            host.height = height
            let changed = IndexSet(items.indices.filter { row in
                guard case let .row(section, drawn) = items[row] else {
                    return false
                }
                return hostedID(section: section, row: drawn) == id
            })
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            (host.superview as? HostedCell)?.pin(offsetX: contentView.bounds.minX, width: contentView.bounds.width)
        }

        func remeasureAll() {
            for host in hosted.values {
                host.height = host.measure(width: hostedWidth.value)
            }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
        }
    }
#endif
