#if os(macOS)
import PRKitCore
import PRKitDesign
import AppKit

/// Jumps, clicks, the comment box and folds.
extension DiffTableContainer {
    /// The line asked for, as drawn. Its file opens if it was folded. Nil if the line isn't showing.
    func lineToShow(_ jump: DiffJump, in section: Int) -> Item? {
        guard let target = jump.line, let side = jump.side,
              let index = document.lines.firstIndex(where: {
                  $0.file == section && (side == .right ? $0.newLine : $0.oldLine) == target
              }),
              let row = path(ofLine: index)?.item else {
            return nil
        }
        if isCollapsed(section) {
            toggleFile(section)
        }
        return .row(section: section, row: row)
    }

    func clicked(_ clicked: Int) {
        guard clicked >= 0, clicked < items.count, case let .row(section, index) = items[clicked],
              case let .line(line) = row(section: section, row: index), !composerHasText else {
            return
        }
        let kind = document.lines[line].kind
        guard kind == .added || kind == .removed || kind == .context else {
            return
        }
        actions.compose(line == composing ? nil : line)
    }

    /// The line being commented on, from the screen, which holds the box.
    func update(composing next: Int?) {
        guard next != composing else {
            return
        }
        composing = next
        highlightLines()
        if let next, let path = path(ofLine: next),
           let row = items.firstIndex(of: .row(section: path.section, row: path.item)) {
            // Once the box has landed and the list has shrunk to make room for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [table] in table.scrollRowToVisible(row) }
        }
    }

    /// Soon, not now: this can come while SwiftUI is updating the table, and the screen holds the box.
    func closeComposer() {
        DispatchQueue.main.async { [actions] in actions.compose(nil) }
    }

    func highlightLines() {
        table.enumerateAvailableRowViews { rowView, row in
            guard case let .row(section, index) = items[row],
                  case let .line(line) = self.row(section: section, row: index) else {
                return
            }
            (rowView as? DiffRowView)?.fill = fill(forLine: line)
        }
    }

    /// A half-written comment holds its file open.
    func toggleFile(_ section: Int) {
        if composingSection == section {
            guard !composerHasText else {
                return
            }
            closeComposer()
        }
        refold(section) { actions.folds.toggle(rows.files[section].foldID) }
    }

    /// `change` flips the file; this animates what that did.
    func refold(_ section: Int, change: () -> Void) {
        let wasCollapsed = isCollapsed(section)
        change()
        guard wasCollapsed != isCollapsed(section), let header = items.firstIndex(of: .header(section)) else {
            headers[section]?.setViewed(viewed.contains(rows.files[section].path))
            return
        }
        let range = IndexSet(integersIn: header + 1 ..< header + 1 + rows.files[section].rows.count)
        // Folded from its pinned header, read from inside: the header stays where it is and the next file comes up
        // under it, at once, rather than the rows fading out above the screen and the diff scrolling back to it.
        let isPinned = contentView.bounds.minY > table.rect(ofRow: header).minY
        rebuild()
        let animation: NSTableView.AnimationOptions = isPinned ? [] : .effectFade
        if wasCollapsed {
            table.insertRows(at: range, withAnimation: animation)
        } else {
            table.removeRows(at: range, withAnimation: animation)
        }
        headers[section]?.setCollapsed(isCollapsed(section))
        headers[section]?.setViewed(viewed.contains(rows.files[section].path))
        if isPinned {
            let end = max(table.bounds.height - contentView.bounds.height, 0)
            contentView.setBoundsOrigin(NSPoint(x: 0, y: min(max(table.rect(ofRow: header).minY, 0), end)))
            reflectScrolledClipView(contentView)
        }
    }

    /// Found by id: a thread's row moves when a comment box opens above it.
    func toggleThread(_ id: String) {
        actions.folds.toggle(id)
        guard let index = rows.threads.firstIndex(where: { $0.id == id }) else {
            return
        }
        for row in items.indices {
            if case let .row(section, drawn) = items[row], self.row(section: section, row: drawn) == .thread(index) {
                _ = hostedRow(section: section, row: drawn)
                remeasure(id)
                return
            }
        }
    }
}
#endif
