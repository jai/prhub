import Foundation
import PRKitCore
import PRKitDesign
import SwiftUI

/// What the reader opened of the lines a diff leaves out, and the files' texts read for it, at one commit of the PR.
struct PRHiddenLines: Sendable {
    /// The commit the texts are of; a newer one's diff starts with nothing opened.
    var head = ""
    var shown = DiffRows.Hidden()
    /// By path. A file is read once and serves every gap of it for as long as the PR is open.
    var texts: [String: Data] = [:]
}

/// The lines a diff leaves out: "Show N hidden lines" on one gap, "Show whole file" on a file. Nothing is read when the
/// diff opens. The first press on a file reads its text at the PR's head, once (`PRsModel.fileText`), and every
/// later press is rows again and no more.
extension PRSession {
    /// What a press asked to see.
    private enum HiddenAsk {
        case gap(DiffRows.GapID)
        case file(String)

        var path: String {
            switch self {
            case let .gap(id): id.path
            case let .file(path): path
            }
        }
    }

    /// "Show N hidden lines" opens a gap, and "Show less" under its lines closes it.
    func toggle(_ gap: DiffRows.Gap) {
        if hiddenLines.shown.gaps.contains(gap.id), gap.state == .open {
            hiddenLines.shown.gaps.remove(gap.id)
            hiddenLines.shown.full.remove(gap.id)
            rebuildRows()
        } else {
            reveal(.gap(gap.id))
        }
    }

    /// "Show N more lines": every line of a long gap that is open.
    func showAll(of gap: DiffRows.Gap) {
        hiddenLines.shown.full.insert(gap.id)
        rebuildRows()
    }

    /// "Show whole file", on or off: every gap of the file at once.
    func setWholeFile(_ isOn: Bool, path: String) {
        if isOn {
            reveal(.file(path))
        } else {
            hiddenLines.shown.files.remove(path)
            rebuildRows()
        }
    }

    /// "Try again" on a gap whose file could not be read: what was asked for is asked again.
    func retry(_ gap: DiffRows.Gap) {
        let asked = hiddenLines.shown.failures[gap.id.path]
        reveal(asked.map { $0.first == nil } == true ? .file(gap.id.path) : .gap(gap.id))
    }

    /// Shows what was asked for: at once from a text already read, else after its one read.
    private func reveal(_ ask: HiddenAsk) {
        guard let head = content?.detail.head else {
            return
        }
        if hiddenLines.head != head {
            hiddenLines = PRHiddenLines(head: head)
        }
        let path = ask.path
        hiddenLines.shown.failures[path] = nil
        if hiddenLines.texts[path] != nil {
            open(ask)
            rebuildRows()
            return
        }
        guard !hiddenLines.shown.loading.contains(path) else {
            return
        }
        hiddenLines.shown.loading.insert(path)
        rebuildRows()
        Task { await read(ask, head: head) }
    }

    private func open(_ ask: HiddenAsk) {
        switch ask {
        case let .gap(id): hiddenLines.shown.gaps.insert(id)
        case let .file(path): hiddenLines.shown.files.insert(path)
        }
    }

    /// Reads the file's text and shows what was asked for, or says on the gap's row why it could not. At a commit
    /// the PR has left, the PR is read again, as its key lines do: the newer diff shows, with nothing opened.
    private func read(_ ask: HiddenAsk, head: String) async {
        let path = ask.path
        var failure: String?
        do {
            let text = try await model.fileText(path, head: head, of: ref)
            guard hiddenLines.head == head else {
                return
            }
            hiddenLines.texts[path] = text
            open(ask)
        } catch is CancellationError {
            failure = nil
        } catch let error as URLError where error.code == .cancelled {
            failure = nil
        } catch PRFileProblem.headMoved {
            if await readNewestCommit() {
                return
            }
            failure = "This PR has moved on to a newer commit. Open it again to see that one."
        } catch {
            failure = Self.words(for: error)
        }
        guard hiddenLines.head == head else {
            return
        }
        hiddenLines.shown.loading.remove(path)
        if let failure {
            var first: Int?
            if case let .gap(id) = ask {
                first = id.first
            }
            hiddenLines.shown.failures[path] = DiffRows.Hidden.Failure(first: first, words: failure)
        }
        rebuildRows()
    }

    /// Why a file's text could not be read, for its gap's row.
    static func words(for error: any Error) -> String {
        switch error as? PRFileProblem {
        case .tooLarge: "This file is too large to show."
        case .binary: "This file is binary."
        case .missing: "There is no file at this path to show."
        case .headMoved, nil: error.localizedDescription
        }
    }

    /// A line was picked to comment on, or nil to close its box. A line the diff does not show takes a comment only
    /// where it can be kept for its file: where the PR's review is on GitHub.
    func compose(_ line: Int?, in document: DiffDocument) {
        if let line, document.lines.indices.contains(line), document.lines[line].isOutsideDiff, !usesPendingReview {
            return
        }
        composingLine = line
    }

    /// A comment written on a line the diff does not show, kept for the review as a comment on the line's file with
    /// the line named in its words: GitHub takes a line comment only on a line of the diff's hunks.
    func addPendingOnFile(_ text: String, path: String, line: Int) {
        discardText(for: .line(path: path, line: line, side: .right))
        addDrafts([PRDraftComment(
            id: UUID(), path: path, line: line, side: .right, body: Self.onFileBody(text, line: line), isFile: true
        )])
    }

    /// As a comment GitHub refused on its line reads once it is sent to its file (`PRPendingSync.addToFile`).
    static func onFileBody(_ text: String, line: Int) -> String {
        "Line \(line): \(text)"
    }

    /// Said in the box of a line the diff does not show.
    static let onFileCaption = "This line isn't in the diff, so the comment goes on the file."
}
