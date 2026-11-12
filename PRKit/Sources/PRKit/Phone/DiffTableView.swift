#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI
import UIKit

/// A fixed line height, so the table never measures code: one tall list inside one sideways scroller, a section per file.
/// Threads and the comment box are the rows that size themselves, as wide as the screen and not the table, so they read
/// without scrolling sideways. A tap on a code line highlights it and opens the box under it.
final class DiffTableContainer: UIScrollView, UITableViewDataSource, UITableViewDelegate {
    static let hostedIdentifier = "hosted"
    /// Past this many rows, a file folds with a cross-dissolve: animating each row out would drop frames.
    private static let animatedFoldLimit = 1_500
    private static let controlsClearance: CGFloat = 60

    let table = ReportingTableView()
    let document: DiffDocument
    var rows: DiffRows
    private var viewed: Set<String>
    private(set) var metrics: DiffMetrics
    private var lastJump: DiffJump?
    let actions: DiffActions
    /// The line of the document being commented on.
    var composing: Int?
    private var keyboardObserver: NSObjectProtocol?
    var keyboardObservers: [NSObjectProtocol] = []
    var topInset: CGFloat = 0
    var lastScrollY: CGFloat = 0
    var isKeyboardUp = false
    var isSettlingBars = false
    private var hasPlacedTop = false
    private let backSwipe = BackSwipeKeeper()

    init(
        document: DiffDocument, rows: DiffRows, viewed: Set<String>, font: DiffFont,
        onContent: @escaping () -> Void, actions: DiffActions
    ) {
        self.document = document
        self.rows = rows
        self.viewed = viewed
        self.actions = actions
        metrics = DiffMetrics(font, traits: UITraitCollection.current)
        super.init(frame: .zero)
        isDirectionalLockEnabled = true
        alwaysBounceVertical = false
        // The code stops at its edges: a bounce would pull it off the screen's edge, with the header cut where the
        // table ends and the threads pushed off the other side. The table still bounces up and down.
        bounces = false
        showsHorizontalScrollIndicator = false
        // The status bar's tap scrolls one view to the top, and only when one alone asks: the table.
        scrollsToTop = false
        table.onContent = onContent
        table.onContentSize = { [weak self] in self?.settleBars() }
        table.dataSource = self
        table.delegate = self
        applyMetricsToTable()
        table.sectionHeaderTopPadding = 0
        table.separatorStyle = .none
        table.isDirectionalLockEnabled = true
        table.keyboardDismissMode = .interactive
        table.register(DiffLineCell.self, forCellReuseIdentifier: DiffLineCell.identifier)
        table.register(DiffHostedCell.self, forCellReuseIdentifier: Self.hostedIdentifier)
        table.register(DiffFileHeader.self, forHeaderFooterViewReuseIdentifier: DiffFileHeader.identifier)
        // Set by hand, from `update(topInset:)`: the bars leaving must not move the code.
        contentInsetAdjustmentBehavior = .never
        table.contentInsetAdjustmentBehavior = .never
        // Room to read the last line above the floating controls.
        table.contentInset.bottom = Self.controlsClearance
        let belowRows = UITapGestureRecognizer(target: self, action: #selector(tappedBelowRows))
        belowRows.cancelsTouchesInView = false
        table.addGestureRecognizer(belowRows)
        addSubview(table)
        watchKeyboard()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.remeasure(font: self.metrics.font)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a storyboard")
    }

    /// A new font from Settings: the code and headers redraw in it, crossfading, where the reader was.
    func update(font: DiffFont) {
        guard font != metrics.font else {
            return
        }
        remeasure(font: font)
    }

    private func remeasure(font: DiffFont) {
        metrics = DiffMetrics(font, traits: traitCollection)
        applyMetricsToTable()
        setNeedsLayout()
        UIView.transition(with: table, duration: 0.25, options: .transitionCrossDissolve) {
            self.table.reloadData()
        }
    }

    private func applyMetricsToTable() {
        table.estimatedRowHeight = metrics.rowHeight
        table.estimatedSectionHeaderHeight = metrics.fileHeaderHeight
        table.sectionHeaderHeight = metrics.fileHeaderHeight
    }

    /// After a post: the new threads fade in, with the scroll position kept.
    func update(rows: DiffRows) {
        guard rows.stamp != self.rows.stamp else {
            return
        }
        self.rows = rows
        if let composing, path(ofLine: composing) == nil {
            closeComposer()
        }
        UIView.transition(with: table, duration: 0.25, options: .transitionCrossDissolve) {
            self.table.reloadData()
        }
    }

    /// The line being commented on, from the screen, which holds the box.
    func update(composing next: Int?) {
        guard next != composing else {
            return
        }
        let wasComposing = composing != nil
        composing = next
        highlightLines()
        guard let next, let path = path(ofLine: next) else {
            return
        }
        let indexPath = IndexPath(row: path.row, section: path.section)
        if wasComposing {
            table.scrollToRow(at: indexPath, at: .none, animated: true)
        } else {
            followKeyboard()
        }
    }

    /// The space the clock and any bars take. It moves the sticky header and leaves the code where it is, unless the
    /// list is at its very top.
    func update(topInset next: CGFloat) {
        guard next != topInset else {
            return
        }
        let isAtTop = table.contentOffset.y <= -topInset + 1
        topInset = next
        UIView.performWithoutAnimation {
            table.contentInset.top = next
            table.verticalScrollIndicatorInsets.top = next
            if isAtTop {
                table.contentOffset.y = -next
            }
            table.layoutIfNeeded()
        }
        settleBars()
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
            (table.headerView(forSection: section) as? DiffFileHeader)?.setViewed(isNowViewed)
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
        setContentOffset(CGPoint(x: 0, y: contentOffset.y), animated: false)
        if let row = rowToShow(jump, in: section) {
            highlightLines()
            table.scrollToRow(at: IndexPath(row: row, section: section), at: .middle, animated: true)
            return
        }
        highlightLines()
        if table.numberOfRows(inSection: section) > 0 {
            table.scrollToRow(at: IndexPath(row: 0, section: section), at: .top, animated: true)
        } else {
            let end = table.contentSize.height - table.bounds.height
            let top = min(table.rectForHeader(inSection: section).minY, max(end, 0))
            table.setContentOffset(CGPoint(x: 0, y: top), animated: true)
        }
    }

    /// The row of the line asked for, as drawn. Its file opens if it was folded. Nil if the line isn't showing.
    private func rowToShow(_ jump: DiffJump, in section: Int) -> Int? {
        guard let target = jump.line, let side = jump.side,
              let index = document.lines.firstIndex(where: {
                  $0.file == section && (side == .right ? $0.newLine : $0.oldLine) == target
              }),
              let row = path(ofLine: index)?.row else {
            return nil
        }
        if isCollapsed(section) {
            toggleFile(section)
        }
        return row
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var responder = next
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        backSwipe.keep(
            on: window == nil ? nil : (responder as? UIViewController)?.navigationController, over: [self, table]
        )
        // Back on screen, as the reader left it or not: the bars are there to leave by.
        if window != nil {
            setBarsHidden(false)
        }
    }

    /// Runs on every sideways scroll too, which is what keeps the file headers on screen.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bounds.width, CGFloat(DiffDocument.columns + 2) * metrics.columnWidth)
        // Without animation: the tab bar leaving grows this view inside the bars' animation, and an animated frame
        // animates the table's bounds, its scroll position included. The rows then freeze under the finger.
        UIView.performWithoutAnimation {
            table.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            table.layoutIfNeeded()
        }
        // A table with no size yet can't hold an offset, so the first one waits for this.
        if !hasPlacedTop, bounds.height > 0 {
            hasPlacedTop = true
            table.contentOffset.y = -topInset
            lastScrollY = table.contentOffset.y
        }
        contentSize = CGSize(width: width, height: bounds.height)
        for case let header as DiffFileHeader in table.subviews {
            header.pin(toVisibleWidth: bounds.width, offsetX: contentOffset.x)
        }
        for cell in table.visibleCells where cell.reuseIdentifier == Self.hostedIdentifier {
            pinToScreen(cell)
        }
    }

    /// A thread or a key line's note is the screen's width: it stays on screen while the code scrolls sideways, as the
    /// file headers do.
    func pinToScreen(_ cell: UITableViewCell) {
        (cell as? DiffHostedCell)?.offsetX = contentOffset.x
    }

    private var composingSection: Int? {
        composing.map { document.lines[$0].file }
    }

    private var composerHasText: Bool {
        composing.map { !actions.text(document.lines[$0]).wrappedValue.allSatisfy(\.isWhitespace) } ?? false
    }

    private func path(ofLine index: Int) -> IndexPath? {
        let section = document.lines[index].file
        return rows.files[section].rows.firstIndex(of: .line(index)).map { IndexPath(row: $0, section: section) }
    }

    /// A viewed file starts folded, as on GitHub, and a tap on its header still opens it.
    private func isCollapsed(_ section: Int) -> Bool {
        let file = rows.files[section]
        return viewed.contains(file.path) != actions.folds.isFlipped(file.foldID)
    }

    private func row(at indexPath: IndexPath) -> DiffRows.Row {
        rows.files[indexPath.section].rows[indexPath.row]
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        rows.files.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !isCollapsed(section) else {
            return 0
        }
        return rows.files[section].rows.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: DiffFileHeader.identifier)
        guard let header = header as? DiffFileHeader else {
            return nil
        }
        let file = rows.files[section]
        let isViewed = viewed.contains(file.path)
        header.configure(
            file, section: section, isCollapsed: isCollapsed(section), isViewed: isViewed, metrics: metrics
        )
        header.onTap = { [weak self] in self?.toggleFile(section) }
        header.onViewed = { [weak self] in self?.actions.setViewed($0, file.path) }
        header.pin(toVisibleWidth: bounds.width, offsetX: contentOffset.x)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        metrics.fileHeaderHeight
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if case .line = row(at: indexPath) {
            return metrics.rowHeight
        }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch row(at: indexPath) {
        case let .line(index):
            return lineCell(index, at: indexPath)
        case let .thread(index):
            return threadCell(rows.threads[index], at: indexPath)
        case let .draft(index):
            let draft = rows.drafts[index]
            return hostedCell(at: indexPath, id: draft.id) {
                PRDraftCard(draft: draft) { [weak self] in self?.actions.removeDraft(draft) }
            }
        case .note:
            return noteCell(at: indexPath)
        }
    }

}

// MARK: - Comment box and folds

extension DiffTableContainer {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard case let .line(index) = row(at: indexPath), !composerHasText else {
            return
        }
        let kind = document.lines[index].kind
        guard kind == .added || kind == .removed || kind == .context else {
            return
        }
        actions.compose(index == composing ? nil : index)
    }

    /// Soon, not now: this can come while SwiftUI is updating the table, and the screen holds the box.
    func closeComposer() {
        DispatchQueue.main.async { [actions] in actions.compose(nil) }
    }

    private func highlightLines() {
        UIView.animate(withDuration: 0.18) {
            for indexPath in self.table.indexPathsForVisibleRows ?? [] {
                if case let .line(index) = self.row(at: indexPath) {
                    self.table.cellForRow(at: indexPath).map {
                        self.mark($0, line: index, at: indexPath)
                    }
                }
            }
        }
    }

    /// The line ends up just above the box and the keyboard, which only land once the field has focus.
    private func followKeyboard() {
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let composing = self.composing else {
                    return
                }
                if let path = self.path(ofLine: composing) {
                    self.table.scrollToRow(
                        at: IndexPath(row: path.row, section: path.section), at: .bottom, animated: true
                    )
                }
                self.keyboardObserver.map(NotificationCenter.default.removeObserver)
                self.keyboardObserver = nil
            }
        }
    }

    /// A half-written comment holds its file open.
    private func toggleFile(_ section: Int) {
        if composingSection == section {
            guard !composerHasText else {
                return
            }
            closeComposer()
        }
        refold(section) { actions.folds.toggle(rows.files[section].foldID) }
    }

    /// `change` flips the file; this animates what that did. A file folded from its pinned header, read from inside,
    /// folds in place: its header stays where it is on screen and the next file comes up under it, with nothing to fade
    /// or scroll. A long file folds or opens at once too: fading thousands of rows, or the whole diff, flickers.
    private func refold(_ section: Int, change: () -> Void) {
        let wasCollapsed = isCollapsed(section)
        let paths = rows.files[section].rows.indices.map { IndexPath(row: $0, section: section) }
        let headerTop = table.rectForHeader(inSection: section).minY
        let isPinned = table.contentOffset.y + table.contentInset.top > headerTop
        if isPinned || paths.count > Self.animatedFoldLimit {
            UIView.performWithoutAnimation {
                change()
                table.reloadData()
                table.layoutIfNeeded()
                if isPinned {
                    table.contentOffset.y = min(headerTop - table.contentInset.top, maxOffsetY)
                }
            }
        } else {
            table.performBatchUpdates {
                change()
                if wasCollapsed, !isCollapsed(section) {
                    table.insertRows(at: paths, with: .fade)
                } else if !wasCollapsed, isCollapsed(section) {
                    table.deleteRows(at: paths, with: .fade)
                }
            }
        }
        (table.headerView(forSection: section) as? DiffFileHeader)?.setCollapsed(isCollapsed(section), animated: true)
        // A fold changes how much there is to scroll, maybe to nothing: the bars come back rather than wait for a scroll.
        // Not from a pinned header: the bars would push it down. If nothing is left to scroll, `settleBars` brings them.
        if !isPinned {
            setBarsHidden(false)
        }
    }

    /// As far down as the table scrolls: the last row above the floating controls.
    private var maxOffsetY: CGFloat {
        max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
    }

    /// Found by id: a thread's row moves when a comment box opens above it.
    func toggleThread(_ id: String) {
        guard let threadIndex = rows.threads.firstIndex(where: { $0.id == id }) else {
            return
        }
        actions.folds.toggle(id)
        for (section, file) in rows.files.enumerated() {
            guard let stored = file.rows.firstIndex(of: .thread(threadIndex)) else {
                continue
            }
            let path = IndexPath(row: stored, section: section)
            UIView.animate(withDuration: 0.28) {
                self.table.performBatchUpdates { self.table.reconfigureRows(at: [path]) }
            }
            return
        }
    }
}
#endif
