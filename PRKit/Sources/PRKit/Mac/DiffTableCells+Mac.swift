#if os(macOS)
import PRKitCore
import PRKitDesign
import AppKit
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
    required init?(coder: NSCoder) {
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byClipping
        label.cell?.truncatesLastVisibleLine = false
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a storyboard")
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6, dy: 0)
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
    required init?(coder: NSCoder) {
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
        let lineHeight = path.fittingSize.height
        let textY = (height - lineHeight) / 2
        let rotation = chevron.frameCenterRotation
        chevron.frameCenterRotation = 0
        chevron.frame = NSRect(x: inset, y: 0, width: chevronWidth, height: height)
        chevron.frameCenterRotation = rotation
        viewed.frame = NSRect(
            x: width - metrics.viewedTarget, y: 0, width: metrics.viewedTarget, height: height
        )
        change.frame = NSRect(x: viewed.frame.minX - changeWidth, y: textY, width: changeWidth, height: lineHeight)
        // Not from the chevron's frame: turned, its frame is the box around it, wider than it stands.
        let pathX = inset + chevronWidth + Space.sm
        path.frame = NSRect(x: pathX, y: textY, width: change.frame.minX - pathX - Space.sm, height: lineHeight)
    }

    @objc private func clicked() {
        onTap()
    }

    @objc private func viewedClicked() {
        onViewed(!isViewed)
    }
}

extension DiffTableContainer {
    func lineView(_ index: Int) -> NSView {
        let reused = table.makeView(withIdentifier: DiffLineView.identifier, owner: nil) as? DiffLineView
        let view = reused ?? DiffLineView()
        let line = document.lines[index]
        let text = document.text(of: line, limit: DiffDocument.columns)
        view.label.font = metrics.code
        view.label.stringValue = document.isClipped(line) ? "\(text)⋯" : text
        view.setAccessibilityIdentifier("diff-line-\(index)")
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
        case .line: nil
        case let .thread(index): rows.threads[index].id
        case let .draft(index): rows.drafts[index].id.uuidString
        case .note: rows.note?.id
        }
    }

    /// The host for a thread, a draft or the box, kept by id and given its current content.
    func hostedRow(section: Int, row: Int) -> HostedRow? {
        switch self.row(section: section, row: row) {
        case .line:
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
            let draft = rows.drafts[index]
            return host(draft.id.uuidString) {
                PRDraftCard(draft: draft) { [weak self] in self?.actions.removeDraft(draft) }
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
