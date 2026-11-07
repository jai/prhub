import PRKitCore
import PRKitDesign
import Foundation

/// A diff as its files, each a run of rows: its code from the first hunk, with every review thread and pending comment
/// under its line. Git's own header lines are left out, because the file's header says what they say. A file with no
/// hunk, a rename or a binary, keeps them: they are all it has. A thread on a line this diff no longer shows has no place
/// here; the description page lists it.
struct DiffRows: Sendable {
    enum Row: Sendable, Equatable {
        case line(Int)
        case thread(Int)
        case draft(Int)
        /// The note of the key line being looked at, under its line.
        case note
    }

    struct File: Sendable {
        let path: String
        let change: DiffDocument.FileChange
        let rows: [Row]

        /// In the session's folds.
        var foldID: String { "file:\(path)" }
    }

    private struct Anchor: Hashable {
        let path: String
        let line: Int
        let isNewSide: Bool
    }

    let files: [File]
    let threads: [PullRequestDetail.Thread]
    let drafts: [PRDraftComment]
    /// Differs for every build of the rows, so the table knows to reload after a comment is posted.
    let stamp = UUID()
    /// The key line being looked at, and the line of the document it sits on, if this diff shows it.
    let note: PRKeyLines.Item?
    let noteLine: Int?

    /// `changedLinesOnly` leaves out unchanged lines, but keeps one that carries a comment.
    init(
        document: DiffDocument, threads: [PullRequestDetail.Thread], drafts: [PRDraftComment] = [],
        changedLinesOnly: Bool = false, note: PRKeyLines.Item? = nil
    ) {
        self.threads = threads
        self.note = note
        var noteLine: Int?
        self.drafts = drafts
        var anchored: [Anchor: [Row]] = [:]
        for (index, thread) in threads.enumerated() {
            if let line = thread.line {
                let anchor = Anchor(path: thread.path, line: line, isNewSide: thread.diffSide == "RIGHT")
                anchored[anchor, default: []].append(.thread(index))
            }
        }
        for (index, draft) in drafts.enumerated() {
            let anchor = Anchor(path: draft.path, line: draft.line, isNewSide: draft.side == .right)
            anchored[anchor, default: []].append(.draft(index))
        }
        var byFile = [[Row]](repeating: [], count: document.files.count)
        var headers = byFile
        for (index, line) in document.lines.enumerated() where line.kind != .file {
            guard byFile.indices.contains(line.file) else {
                continue
            }
            if line.kind == .meta, byFile[line.file].isEmpty {
                headers[line.file].append(.line(index))
                continue
            }
            let path = document.files[line.file]
            let newSide = line.newLine > 0 ? anchored[Anchor(path: path, line: line.newLine, isNewSide: true)] : nil
            let oldSide = line.oldLine > 0 ? anchored[Anchor(path: path, line: line.oldLine, isNewSide: false)] : nil
            let comments = (newSide ?? []) + (oldSide ?? [])
            let carriesNote = note.map { note in
                note.path == path && note.line == (note.side == "RIGHT" ? line.newLine : line.oldLine)
            } ?? false
            if changedLinesOnly, line.kind == .context, comments.isEmpty, !carriesNote {
                continue
            }
            byFile[line.file].append(.line(index))
            if carriesNote {
                noteLine = index
                byFile[line.file].append(.note)
            }
            byFile[line.file].append(contentsOf: comments)
        }
        self.noteLine = noteLine
        files = document.files.indices.map { index in
            File(
                path: document.files[index], change: document.fileChanges[index],
                rows: byFile[index].isEmpty ? headers[index] : byFile[index]
            )
        }
    }
}
