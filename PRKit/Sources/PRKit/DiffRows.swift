import Foundation
import PRKitCore
import PRKitDesign

/// A diff as its files, each a run of rows: its code from the first hunk, with every review thread and pending comment
/// under its line. Where lines wrap, a very long line is several rows, a piece each. Git's own header lines are left out, because the file's header says what they say. A file with no
/// hunk, a rename or a binary, keeps them: they are all it has. A thread on a line this diff no longer shows has no place
/// here; the description page lists it.
struct DiffRows: Sendable {
    enum Row: Sendable, Equatable {
        case line(Int)
        /// A later piece of a long line, where lines wrap: the line's index, then the piece's.
        case piece(Int, Int)
        /// "Show full line", under the start of a line too long to show whole at first.
        case rest(Int)
        /// "Show less", under the last piece of such a line once it is shown whole.
        case less(Int)
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
        var foldID: String {
            "file:\(path)"
        }
    }

    /// A line whatever the diff's order: which long lines the reader asked to see whole outlasts a sync.
    struct LineID: Hashable, Sendable {
        let path: String
        let oldLine: Int
        let newLine: Int

        init(_ line: DiffDocument.Line, in document: DiffDocument) {
            path = document.files.indices.contains(line.file) ? document.files[line.file] : ""
            oldLine = line.oldLine
            newLine = line.newLine
        }
    }

    /// How long lines are shown: wrapped in the diff's width, the default, or on one row that scrolls sideways.
    struct LongLines: Sendable, Equatable {
        var wraps = true
        /// Lines that open cut (`DiffDocument.opensCut`) and that the reader opened in full.
        var whole: Set<LineID> = []
    }

    private struct Anchor: Hashable {
        let path: String
        let line: Int
        let isNewSide: Bool
    }

    /// The rows under the first of a line that opens cut: "Show full line", or the rest of its pieces and "Show less".
    private static func rowsUnder(_ index: Int, isCut: Bool, in document: DiffDocument) -> [Row] {
        isCut ? [.rest(index)] : (1 ..< document.pieceCount(ofLine: index)).map { .piece(index, $0) } + [.less(index)]
    }

    /// The comment rows by the line they sit under, and each placed pending comment's line: a thread on its line, a
    /// pending reply straight under the thread it answers, a pending line comment on its own line.
    private static func anchor(
        threads: [PullRequestDetail.Thread], pending: [PRPendingComment]
    ) -> (rows: [Anchor: [Row]], pending: [String: Anchor]) {
        var anchored: [Anchor: [Row]] = [:]
        var anchors: [String: Anchor] = [:]
        for (index, thread) in threads.enumerated() {
            if let line = thread.line {
                let anchor = Anchor(path: thread.path, line: line, isNewSide: thread.diffSide == "RIGHT")
                anchored[anchor, default: []].append(.thread(index))
                // A pending reply sits straight under the thread it answers.
                for (reply, comment) in pending.enumerated() where comment.thread == thread.id {
                    anchored[anchor, default: []].append(.draft(reply))
                    anchors[comment.id] = anchor
                }
            }
        }
        for (index, comment) in pending.enumerated() where comment.thread == nil {
            if let line = comment.line {
                let anchor = Anchor(path: comment.path, line: line, isNewSide: comment.side == .right)
                anchored[anchor, default: []].append(.draft(index))
                anchors[comment.id] = anchor
            }
        }
        return (anchored, anchors)
    }

    let files: [File]
    let threads: [PullRequestDetail.Thread]
    /// The comments of the review not submitted yet. A `draft` row draws one, by its place here.
    let pending: [PRPendingComment]
    /// The pending comments that have a row here, by id: under their line, or under the thread they reply to. The PR's
    /// page lists the rest.
    let placed: Set<String>
    /// Differs for every build of the rows, so the table knows to reload after a comment is posted.
    let stamp = UUID()
    /// Long lines wrap in the diff's width; otherwise each is one row and the code scrolls sideways.
    let wraps: Bool
    /// The lines shown cut, their start over "Show full line": the first piece is drawn to a number of rows.
    let cut: Set<Int>
    /// The key line being looked at, and the line of the document it sits on, if this diff shows it.
    let note: PRKeyLines.Item?
    let noteLine: Int?

    /// `changedLinesOnly` leaves out unchanged lines, but keeps one that carries a comment.
    init(
        document: DiffDocument, threads: [PullRequestDetail.Thread], pending: [PRPendingComment] = [],
        changedLinesOnly: Bool = false, note: PRKeyLines.Item? = nil, longLines: LongLines = LongLines()
    ) {
        wraps = longLines.wraps
        self.threads = threads
        self.note = note
        var noteLine: Int?
        var cut: Set<Int> = []
        self.pending = pending
        let (anchored, anchors) = Self.anchor(threads: threads, pending: pending)
        var shown: Set<Anchor> = []
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
            let newAnchor = Anchor(path: path, line: line.newLine, isNewSide: true)
            let oldAnchor = Anchor(path: path, line: line.oldLine, isNewSide: false)
            let newSide = line.newLine > 0 ? anchored[newAnchor] : nil
            let oldSide = line.oldLine > 0 ? anchored[oldAnchor] : nil
            let comments = (newSide ?? []) + (oldSide ?? [])
            if newSide != nil {
                shown.insert(newAnchor)
            }
            if oldSide != nil {
                shown.insert(oldAnchor)
            }
            let carriesNote = note.map { note in
                note.path == path && note.line == (note.side == "RIGHT" ? line.newLine : line.oldLine)
            } ?? false
            if changedLinesOnly, line.kind == .context, comments.isEmpty, !carriesNote {
                continue
            }
            byFile[line.file].append(.line(index))
            if longLines.wraps, document.opensCut(index) {
                let isCut = !longLines.whole.contains(LineID(line, in: document))
                if isCut {
                    cut.insert(index)
                }
                byFile[line.file].append(contentsOf: Self.rowsUnder(index, isCut: isCut, in: document))
            }
            if carriesNote {
                noteLine = index
                byFile[line.file].append(.note)
            }
            byFile[line.file].append(contentsOf: comments)
        }
        self.noteLine = noteLine
        self.cut = cut
        placed = Set(anchors.filter { shown.contains($0.value) }.keys)
        files = document.files.indices.map { index in
            File(
                path: document.files[index], change: document.fileChanges[index],
                rows: byFile[index].isEmpty ? headers[index] : byFile[index]
            )
        }
    }
}

extension DiffRows.Row {
    /// The line of the document a code row draws, whichever piece of it.
    var codeLine: Int? {
        switch self {
        case let .line(index), let .piece(index, _): index
        case .rest, .less, .thread, .draft, .note: nil
        }
    }

    /// A row that belongs to the line above it: a later piece, "Show full line" or "Show less".
    var continuesLine: Bool {
        switch self {
        case .piece, .rest, .less: true
        case .line, .thread, .draft, .note: false
        }
    }
}
