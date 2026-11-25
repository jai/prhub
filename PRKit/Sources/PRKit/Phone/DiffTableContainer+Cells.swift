#if os(iOS)
    import PRKitCore
    import PRKitDesign
    import SwiftUI
    import UIKit

    extension DiffTableContainer {
        /// A line of code, or one piece of a long one where lines wrap: the line's numbers are beside its first.
        func lineCell(_ index: Int, piece: Int = 0, at indexPath: IndexPath) -> UITableViewCell {
            let cell = table.dequeueReusableCell(withIdentifier: DiffLineCell.identifier, for: indexPath)
            let line = document.lines[index]
            if rows.wraps {
                // Before the table has a width a row is asked for by a test alone, and nothing is narrow enough to wrap.
                let wrap = wrap ?? DiffWrap(metrics: metrics, width: DiffWrap.unbounded)
                (cell as? DiffLineCell)?.configure(
                    line: line, wrapped: wrap.text(line: index, piece: piece, of: document), isFirstPiece: piece == 0,
                    rows: rows.cut.contains(index) ? DiffWrap.shownRows : 0, metrics: metrics,
                    digits: document.lineNumberDigits
                )
            } else {
                let text = document.text(of: line, limit: DiffDocument.columns)
                (cell as? DiffLineCell)?.configure(
                    line: line, text: document.isClipped(line) ? "\(text)⋯" : text,
                    metrics: metrics, digits: document.lineNumberDigits
                )
            }
            mark(cell, line: index, at: indexPath)
            cell.accessibilityIdentifier = piece == 0 ? "diff-line-\(index)" : "diff-line-\(index)-piece-\(piece)"
            return cell
        }

        /// "Show full line", under the start of a very long line, on the line's own colour; "Show less" under its end.
        func restCell(_ index: Int, isLess: Bool = false, at indexPath: IndexPath) -> UITableViewCell {
            let cell = table.dequeueReusableCell(withIdentifier: DiffRestCell.identifier, for: indexPath)
            let line = document.lines[index]
            (cell as? DiffRestCell)?.configure(
                title: isLess ? DiffWrap.lessTitle : DiffWrap.restTitle(line), metrics: metrics, digits: document.lineNumberDigits
            )
            cell.backgroundColor = DiffStyle.background(line.kind)
            cell.accessibilityIdentifier = "diff-line-\(index)-\(isLess ? "less" : "rest")"
            return cell
        }

        /// Yellow for the line being commented on and the key line being looked at.
        func mark(_ cell: UITableViewCell, line index: Int, at _: IndexPath) {
            let isKeyLine = index == rows.noteLine
            let isSelected = index == composing || isKeyLine
            cell.backgroundColor = isSelected ? DiffStyle.selectedLine : DiffStyle.background(document.lines[index].kind)
            cell.accessibilityValue = isKeyLine ? "selected" : nil
        }

        /// `id` keeps a reused cell's SwiftUI state from following it: a half-typed reply would show under another thread.
        func hostedCell(
            at indexPath: IndexPath, id: some Hashable, @ViewBuilder content: () -> some View
        ) -> UITableViewCell {
            let cell = table.dequeueReusableCell(withIdentifier: Self.hostedIdentifier, for: indexPath)
            let width = bounds.width - DiffStyle.threadInset * 2
            cell.selectionStyle = .none
            cell.contentConfiguration = UIHostingConfiguration {
                content()
                    .id(id)
                    .environment(\.openURL, actions.openURL)
                    .frame(width: width)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .margins(.all, DiffStyle.threadInset)
            pinToScreen(cell)
            return cell
        }

        func threadCell(_ thread: PullRequestDetail.Thread, at indexPath: IndexPath) -> UITableViewCell {
            let isCollapsed = thread.isResolved != actions.folds.isFlipped(thread.id)
            return hostedCell(at: indexPath, id: thread.id) {
                PRThreadCard(
                    thread: thread, isCollapsed: isCollapsed, replyText: actions.replyText(thread),
                    onToggle: { [weak self] in self?.toggleThread(thread.id) },
                    reply: { [weak self] text in try await self?.actions.reply(thread, text) },
                    setResolved: { [weak self] in try await self?.actions.setResolved(thread, $0) }
                )
            }
        }

        func noteCell(at indexPath: IndexPath) -> UITableViewCell {
            guard let note = rows.note else {
                return UITableViewCell()
            }
            return hostedCell(at: indexPath, id: note.id) {
                PRKeyLineNote(item: note, actions: actions)
            }
        }
    }

    // MARK: - The bars and the keyboard

    extension DiffTableContainer {
        /// The bars leave as the reader goes down the code and come back as they go up (`DiffBars`). Only a finger's scroll
        /// hides them: a jump to a key line shouldn't.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === table else {
                return
            }
            let scroll = barsScroll(byFinger: table.isTracking || table.isDecelerating)
            if !scroll.byFinger || scroll.offset >= scroll.bottom || abs(scroll.moved) >= DiffBars.dragThreshold {
                lastScrollY = scroll.offset
            }
            apply(DiffBars.decide(scroll))
            reportFileOnTop()
        }

        /// The file whose header or lines are just under the bars.
        private func reportFileOnTop() {
            let top = CGPoint(x: 0, y: table.contentOffset.y + topInset + 1)
            if let section = table.indexPathForRow(at: top)?.section ?? table.indexPathsForVisibleRows?.first?.section {
                actions.showsFileOnTop(section)
            }
        }

        /// The status bar's tap goes to the top, where the bars belong.
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            if scrollView === table {
                setBarsHidden(false)
            }
            return scrollView === table
        }

        /// After the list changed under the bars without a finger: a fold, a new size, the bars' own inset. Once the layout
        /// has settled, and once however often it asks.
        func settleBars() {
            guard !isSettlingBars else {
                return
            }
            isSettlingBars = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                isSettlingBars = false
                if DiffBars.decide(barsScroll(byFinger: false)) == .show {
                    actions.setBarsHidden(false)
                }
            }
        }

        func barsScroll(byFinger: Bool) -> DiffBars.Scroll {
            DiffBars.Scroll(
                offset: table.contentOffset.y, moved: table.contentOffset.y - lastScrollY,
                contentHeight: table.contentSize.height, visibleHeight: table.bounds.height,
                topInset: table.contentInset.top, bottomInset: table.contentInset.bottom, byFinger: byFinger,
                isKeyboardUp: isKeyboardUp
            )
        }

        private func apply(_ decision: DiffBars.Decision) {
            switch decision {
            case .show: setBarsHidden(false)
            case .hide: setBarsHidden(true)
            case .keep: break
            }
        }

        /// Soon, not now: a scroll or a fold can come while SwiftUI is updating the table, and the screen holds the bars.
        func setBarsHidden(_ isHidden: Bool) {
            DispatchQueue.main.async { [actions] in actions.setBarsHidden(isHidden) }
        }

        /// A tap below the last row, where there's no code to tap, brings the bars back.
        @objc func tappedBelowRows(_ tap: UITapGestureRecognizer) {
            if tap.location(in: table).y > table.contentSize.height {
                setBarsHidden(false)
            }
        }

        func watchKeyboard() {
            let center = NotificationCenter.default
            let observe: (Notification.Name, Bool) -> NSObjectProtocol = { [weak self] name, isUp in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        self?.isKeyboardUp = isUp
                        self?.actions.setKeyboardUp(isUp)
                    }
                }
            }
            keyboardObservers = [
                observe(UIResponder.keyboardWillShowNotification, true),
                observe(UIResponder.keyboardWillHideNotification, false),
            ]
        }
    }

    /// UIKit stops the back swipe while the nav bar is hidden, and the bars leave while the diff is read; the diff's sideways
    /// scroll would take the swipe from the screen's edge besides. This keeps it, for as long as the diff is on screen,
    /// whenever there's a screen to go back to: the swipe begins with the bars gone, and the diff's scrolls wait for it.
    final class BackSwipeKeeper: NSObject, UIGestureRecognizerDelegate {
        private weak var navigation: UINavigationController?
        private weak var previous: UIGestureRecognizerDelegate?
        private var previousContentPopEnabled: Bool?
        /// The diff's scroll views, which give way to the swipe.
        private var scrollViews: [Weak] = []

        private struct Weak {
            weak var view: UIScrollView?
        }

        func keep(on next: UINavigationController?, over views: [UIScrollView]) {
            scrollViews = views.map(Weak.init)
            guard next !== navigation else {
                return
            }
            navigation?.interactivePopGestureRecognizer?.delegate = previous
            if let previousContentPopEnabled {
                navigation?.interactiveContentPopGestureRecognizer?.isEnabled = previousContentPopEnabled
            }
            navigation = next
            previous = next?.interactivePopGestureRecognizer?.delegate
            next?.interactivePopGestureRecognizer?.delegate = self
            previousContentPopEnabled = next?.interactiveContentPopGestureRecognizer?.isEnabled
            // A rightward code pan at its left edge stays in the diff. Back still starts at the screen's edge.
            next?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            (navigation?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(
            _: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            scrollViews.contains { $0.view?.panGestureRecognizer === other }
        }
    }
#endif
