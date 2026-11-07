#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI
import UIKit

extension DiffTableContainer {
    func lineCell(_ index: Int, at indexPath: IndexPath) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: DiffLineCell.identifier, for: indexPath)
        let line = document.lines[index]
        let text = document.text(of: line, limit: DiffDocument.columns)
        (cell as? DiffLineCell)?.label.text = document.isClipped(line) ? "\(text)⋯" : text
        mark(cell, line: index, at: indexPath)
        cell.accessibilityIdentifier = "diff-line-\(index)"
        return cell
    }

    /// Yellow for the line being commented on and the key line being looked at.
    func mark(_ cell: UITableViewCell, line index: Int, at indexPath: IndexPath) {
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
            PRKeyLineNote(item: note) { [actions] in actions.closeNote() }
        }
    }
}

// MARK: - The bars and the keyboard

extension DiffTableContainer {
    /// The bars leave as the reader goes down the code and come back as they go up. Only a finger's scroll counts: a
    /// jump to a key line shouldn't move them.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === table, table.isTracking || table.isDecelerating else {
            lastScrollY = scrollView.contentOffset.y
            return
        }
        let offset = table.contentOffset.y
        let moved = offset - lastScrollY
        // The bounce at the end of the list runs back up, and isn't the reader going back.
        let bottom = table.contentSize.height + table.contentInset.bottom - table.bounds.height
        guard offset < bottom, abs(moved) >= Self.barsDragThreshold else {
            if offset >= bottom {
                lastScrollY = offset
            }
            return
        }
        lastScrollY = offset
        if moved < 0 {
            actions.setBarsHidden(false)
        } else if offset > 0 {
            // Not before the code has passed the top: the top inset shrinking there would pull the list down under the
            // finger, which reads as going back up, and the bars would flicker.
            actions.setBarsHidden(true)
        }
    }

    func watchKeyboard() {
        let center = NotificationCenter.default
        let observe: (Notification.Name, Bool) -> NSObjectProtocol = { [weak self] name, isUp in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self?.actions.setKeyboardUp(isUp) }
            }
        }
        keyboardObservers = [
            observe(UIResponder.keyboardWillShowNotification, true),
            observe(UIResponder.keyboardWillHideNotification, false),
        ]
    }
}

/// UIKit stops the back swipe while the nav bar is hidden, and the bars leave while the diff is read. This keeps it,
/// for as long as the diff is on screen, whenever there's a screen to go back to.
final class BackSwipeKeeper: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var previous: UIGestureRecognizerDelegate?

    func keep(on next: UINavigationController?) {
        guard next !== navigation else {
            return
        }
        navigation?.interactivePopGestureRecognizer?.delegate = previous
        navigation = next
        previous = next?.interactivePopGestureRecognizer?.delegate
        next?.interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigation?.viewControllers.count ?? 0) > 1
    }
}
#endif
