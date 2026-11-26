import PRKitCore
import PRKitDesign
import SwiftUI

/// Where a comment on a key line goes.
enum PRKeyLinePlace: Equatable, Sendable {
    /// On its line, which the diff shows: the line's place in the document, and where the line's comment box writes.
    case line(Int, path: String, line: Int, side: PRDiffSide)
    /// On its file: the diff does not show the line, and GitHub takes a line comment only on a line it shows.
    case file
}

/// What a press of a key line's Add to review did.
enum PRKeyLineDraftStep: Equatable, Sendable {
    /// A comment box opened with the key line's words in it. Nothing is kept until its Add to review.
    case openedBox
    /// The review has a comment there already, under its line in the diff: the diff shows it.
    case shownUnderItsLine
    /// The review has a comment there already, listed on the PR's page: the caller goes there.
    case listedOnThePage
    /// Nothing: there is no place a comment on this key line can be kept.
    case nothing
}

/// What a key line's row and note ask about a comment on it. The diff's table holds these, as it holds `DiffActions`.
struct PRKeyLineDraftActions {
    /// Read in a view's body, so the tick follows the review's pending comments.
    var isAdded: (PRKeyLines.Item) -> Bool = { _ in false }
    var offers: (PRKeyLines.Item) -> Bool = { _ in false }
    var add: (PRKeyLines.Item) -> Void = { _ in }
}

/// A key line's words made into a comment of the review not submitted yet: the press opens a comment box with the
/// words in it, to be changed, and the box's own Add to review keeps them. Whether a key line has one is read from the
/// review's pending comments, GitHub's and the device's, never kept apart from them.
extension PRSession {
    /// What a comment on a file says first when its line is not in the diff, as `PRPendingSync.addToFile` writes it.
    static func linePrefix(_ line: Int) -> String {
        "Line \(line): "
    }

    func place(of item: PRKeyLines.Item) -> PRKeyLinePlace {
        guard case let .document(document, _) = content?.diff, let file = document.files.firstIndex(of: item.path),
              let index = document.lines.firstIndex(where: {
                  $0.file == file && (item.side == PRDiffSide.left.rawValue ? $0.oldLine : $0.newLine) == item.line
              }),
              case let .line(path, line, side) = PRComposerTarget(document, line: document.lines[index])
        else {
            return .file
        }
        return .line(index, path: path, line: line, side: side)
    }

    /// The review's pending comment on this key line, if it has one: on the key line's line, or on its file with the
    /// line said first, as one kept while the diff did not show the line.
    func pendingComment(on item: PRKeyLines.Item) -> PRPendingComment? {
        var (line, side) = (item.line, PRDiffSide(rawValue: item.side) ?? .right)
        if case let .line(_, _, shownLine, shownSide) = place(of: item) {
            (line, side) = (shownLine, shownSide)
        }
        let own = pending.filter { $0.thread == nil && $0.path == item.path }
        return own.first { !$0.isFile && $0.line == line && $0.side == side }
            ?? own.first { $0.isFile && $0.body.hasPrefix(Self.linePrefix(item.line)) }
    }

    /// Whether a press can keep a comment on this key line, or show the one there is. A line the diff does not show
    /// needs a comment on its file, which only GitHub's pending review takes.
    func offersAddToReview(_ item: PRKeyLines.Item) -> Bool {
        guard case .document = content?.diff else {
            return false
        }
        return place(of: item) != .file || usesPendingReview || pendingComment(on: item) != nil
    }

    /// The words of the box for a key line whose line the diff does not show.
    func offDiffText(for item: PRKeyLines.Item) -> Binding<String> {
        let key = "key-line-file:\(item.id)"
        return Binding { self.writing[key] ?? "" } set: { self.writing[key] = $0 }
    }

    /// A key line's Add to review. With a pending comment there already, it is shown and nothing is added. Otherwise
    /// the diff goes to the line and its comment box opens with the key line's words, unless words are waiting in
    /// it. For a line the diff does not show, the same box opens for a comment on the file. Nothing is kept, on GitHub
    /// or on the device, until the box's own button is pressed.
    @discardableResult
    func addToReview(_ item: PRKeyLines.Item) -> PRKeyLineDraftStep {
        guard offersAddToReview(item) else {
            return .nothing
        }
        if let existing = pendingComment(on: item) {
            if pendingOffDiff.contains(where: { $0.id == existing.id }) {
                pendingListShows += 1
                return .listedOnThePage
            }
            show(item)
            return .shownUnderItsLine
        }
        show(item)
        switch place(of: item) {
        case let .line(index, path, line, side):
            prefill(text(for: .line(path: path, line: line, side: side)), with: item)
            withAnimation(AppMotion.fold) {
                composingOffDiff = nil
                composingLine = index
            }
        case .file:
            prefill(offDiffText(for: item), with: item)
            withAnimation(AppMotion.fold) {
                composingLine = nil
                composingOffDiff = item
            }
        }
        return .openedBox
    }

    private func prefill(_ text: Binding<String>, with item: PRKeyLines.Item) {
        if text.wrappedValue.allSatisfy(\.isWhitespace) {
            text.wrappedValue = item.why
        }
    }

    /// The box's Add to review for a key line the diff does not show: a pending comment on the file, its words saying
    /// which line they are about.
    func addToFile(_ text: String, for item: PRKeyLines.Item) {
        closeOffDiffBox(for: item)
        addDrafts([PRDraftComment(
            id: UUID(), path: item.path, line: item.line, side: PRDiffSide(rawValue: item.side) ?? .right,
            body: Self.linePrefix(item.line) + text, isFile: true
        )])
    }

    /// Cancel, and what a kept comment leaves: the box closed and its words gone.
    func closeOffDiffBox(for item: PRKeyLines.Item) {
        withAnimation(AppMotion.fold) {
            writing["key-line-file:\(item.id)"] = nil
            composingOffDiff = nil
        }
    }
}
