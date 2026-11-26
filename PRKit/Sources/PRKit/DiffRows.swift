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
        /// "Show 12 hidden lines", where the diff leaves lines of the file out: its place in `gaps`.
        case gap(Int)
        /// "Show 1,600 more lines", between the first and the last lines of a long gap that is open.
        case gapMore(Int)
        /// "Show less", under the lines of a gap opened on its own.
        case gapLess(Int)
    }

    struct File: Sendable {
        let path: String
        let change: DiffDocument.FileChange
        let rows: [Row]
        /// "Show whole file" in the file's menu: on, off, or nil where there is nothing more to show.
        var showsWhole: Bool?

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

    fileprivate struct Anchor: Hashable {
        let path: String
        let line: Int
        let isNewSide: Bool
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
    /// The runs of lines the diff leaves out that have a row here (`DiffGaps.swift`).
    let gaps: [Gap]

    /// `changedLinesOnly` leaves out unchanged lines, but keeps one that carries a comment. `hidden` says which of
    /// the lines the diff leaves out are shown; a file's are rows only once `document` has its text.
    init(
        document: DiffDocument, threads: [PullRequestDetail.Thread], pending: [PRPendingComment] = [],
        changedLinesOnly: Bool = false, note: PRKeyLines.Item? = nil, longLines: LongLines = LongLines(),
        hidden: Hidden = Hidden()
    ) {
        wraps = longLines.wraps
        self.threads = threads
        self.note = note
        self.pending = pending
        let (anchored, anchors) = Self.anchor(threads: threads, pending: pending)
        var builder = Builder(
            document: document, anchored: anchored, changedLinesOnly: changedLinesOnly, note: note,
            longLines: longLines, hidden: hidden
        )
        files = builder.files()
        noteLine = builder.noteLine
        cut = builder.cut
        gaps = builder.gaps
        placed = Set(anchors.filter { builder.shown.contains($0.value) }.keys)
    }
}

/// Builds a diff's rows in one pass over its lines. The lines a diff leaves out cost that pass nothing: where they lie
/// is read from the hunks the document already holds, as each hunk's own row is met.
private struct Builder {
    let document: DiffDocument
    let anchored: [DiffRows.Anchor: [DiffRows.Row]]
    let changedLinesOnly: Bool
    let note: PRKeyLines.Item?
    let longLines: DiffRows.LongLines
    let hidden: DiffRows.Hidden
    var shown: Set<DiffRows.Anchor> = []
    var cut: Set<Int> = []
    var noteLine: Int?
    var gaps: [DiffRows.Gap] = []
    /// How many gaps each file has so far, with a row or not: a gap's place among its file's is the same in every build.
    private var gapCounts: [Int] = []
    /// The line after the last hunk met of each file: 1 before its first.
    private var hunkEnds: [Int] = []
    /// The files with a comment or the key line's note on one of their lines, by the file's index.
    private var carries: [Bool] = []
    /// Lines wrap and one at least opens cut: such a line has rows of its own under it.
    private var cutsLines = false

    mutating func files() -> [DiffRows.File] {
        var byFile = [[DiffRows.Row]](repeating: [], count: document.files.count)
        var headers = byFile
        gapCounts = [Int](repeating: 0, count: document.files.count)
        hunkEnds = [Int](repeating: 1, count: document.files.count)
        let paths = Set(anchored.keys.map(\.path) + (note.map { [$0.path] } ?? []))
        carries = document.files.map(paths.contains)
        cutsLines = longLines.wraps && !document.pieces.isEmpty
        var nextHunk = 0
        // The diff's own lines: a file's text read since follows them, and is rows only where a gap is open.
        for (index, line) in document.lines[..<document.diffLineCount].enumerated() where line.kind != .file {
            // Every `@@` row is a hunk, in the hunks' order, whether or not its file has a place here.
            if line.kind == .hunk {
                nextHunk += 1
            }
            guard byFile.indices.contains(line.file) else {
                continue
            }
            if line.kind == .meta, byFile[line.file].isEmpty {
                headers[line.file].append(.line(index))
                continue
            }
            if line.kind == .hunk, document.hunks.indices.contains(nextHunk - 1) {
                byFile[line.file].append(contentsOf: gapRows(before: document.hunks[nextHunk - 1]))
            }
            append(line, at: index, to: &byFile[line.file])
        }
        return document.files.indices.map { file in
            let rows = (byFile[file].isEmpty ? headers[file] : byFile[file]) + gapRows(after: file)
            return DiffRows.File(
                path: document.files[file], change: document.fileChanges[file], rows: rows, showsWhole: showsWhole(file)
            )
        }
    }

    /// A line's own rows: the line, the rest of a long one, the key line's note and the comments on it. None for an
    /// unchanged line left out by `changedLinesOnly`.
    private mutating func append(_ line: DiffDocument.Line, at index: Int, to rows: inout [DiffRows.Row]) {
        // Nearly every line of nearly every diff: nothing sits under it, so nothing is looked up for it.
        if !carries[line.file], !(cutsLines && document.opensCut(index)) {
            if !changedLinesOnly || line.kind != .context {
                rows.append(.line(index))
            }
            return
        }
        let path = document.files[line.file]
        let newAnchor = DiffRows.Anchor(path: path, line: line.newLine, isNewSide: true)
        let oldAnchor = DiffRows.Anchor(path: path, line: line.oldLine, isNewSide: false)
        let newSide = line.newLine > 0 ? anchored[newAnchor] : nil
        let oldSide = line.oldLine > 0 ? anchored[oldAnchor] : nil
        let comments = (newSide ?? []) + (oldSide ?? [])
        let carriesNote = note.map { note in
            note.path == path && note.line == (note.side == "RIGHT" ? line.newLine : line.oldLine)
        } ?? false
        if changedLinesOnly, line.kind == .context, comments.isEmpty, !carriesNote {
            return
        }
        if newSide != nil {
            shown.insert(newAnchor)
        }
        if oldSide != nil {
            shown.insert(oldAnchor)
        }
        rows.append(.line(index))
        if longLines.wraps, document.opensCut(index) {
            let isCut = !longLines.whole.contains(DiffRows.LineID(line, in: document))
            if isCut {
                cut.insert(index)
            }
            rows.append(contentsOf: Self.rowsUnder(index, isCut: isCut, in: document))
        }
        if carriesNote {
            noteLine = index
            rows.append(.note)
        }
        rows.append(contentsOf: comments)
    }

    /// The rows under the first of a line that opens cut: "Show full line", or the rest of its pieces and "Show less".
    private static func rowsUnder(_ index: Int, isCut: Bool, in document: DiffDocument) -> [DiffRows.Row] {
        isCut ? [.rest(index)] : (1 ..< document.pieceCount(ofLine: index)).map { .piece(index, $0) } + [.less(index)]
    }

    // MARK: - The lines the diff leaves out

    /// What the diff leaves out before `hunk`: from the hunk before it, or from the file's first line.
    private mutating func gapRows(before hunk: DiffDocument.Hunk) -> [DiffRows.Row] {
        guard document.shapes.indices.contains(hunk.file) else {
            return []
        }
        let first = hunkEnds[hunk.file]
        hunkEnds[hunk.file] = hunk.newEnd
        return gapRows(file: hunk.file, first: first, last: hunk.newFirst - 1)
    }

    /// What the diff leaves out after a file's last hunk: unknown until the file's text is read, and nothing where
    /// the hunk says the file ends in it. A file with no hunk, a rename, has all of its lines here.
    private mutating func gapRows(after file: Int) -> [DiffRows.Row] {
        guard document.shapes.indices.contains(file) else {
            return []
        }
        guard let last = document.hunks[document.shapes[file].hunks].last else {
            return gapRows(file: file, first: 1, last: nil)
        }
        return last.reachesEnd ? [] : gapRows(file: file, first: last.newEnd, last: nil)
    }

    /// Lines `first` to `last` of a file, which its diff leaves out: one row that offers them, or, opened, the lines
    /// themselves. `last` nil is the file's end. With `changedLinesOnly` they are unchanged lines like any other:
    /// only one that carries a comment or the key line's note shows.
    private mutating func gapRows(file: Int, first: Int, last knownLast: Int?) -> [DiffRows.Row] {
        let text = document.texts[file]
        let last = knownLast ?? text?.count
        guard document.shapes[file].hidesLines, last.map({ $0 >= first }) ?? true else {
            return []
        }
        let path = document.files[file]
        let id = DiffRows.GapID(path: path, first: first)
        let ordinal = gapCounts[file]
        gapCounts[file] += 1
        let isWhole = hidden.files.contains(path)
        guard let text, let last, isWhole || hidden.gaps.contains(id) else {
            if changedLinesOnly {
                return []
            }
            gaps.append(DiffRows.Gap(
                file: file, ordinal: ordinal, id: id, last: last, state: hidden.state(of: id, ordinal: ordinal)
            ))
            return [.gap(gaps.count - 1)]
        }
        let count = last - first + 1
        let isLong = count > DiffRows.gapLimit && !hidden.full.contains(id)
        let edge = DiffRows.gapEdge
        let runs = isLong ? [first ... first + edge - 1, last - edge + 1 ... last] : [first ... last]
        gaps.append(DiffRows.Gap(
            file: file, ordinal: ordinal, id: id, last: last, state: .open, more: isLong ? count - edge * 2 : 0
        ))
        let gap = gaps.count - 1
        var rows: [DiffRows.Row] = []
        for (place, run) in runs.enumerated() {
            if place > 0, !changedLinesOnly {
                rows.append(.gapMore(gap))
            }
            for number in run {
                append(document.lines[text.base + number - 1], at: text.base + number - 1, to: &rows)
            }
        }
        // A file shown whole is put back by its own menu, not gap by gap.
        if !changedLinesOnly, !isWhole {
            rows.append(.gapLess(gap))
        }
        return rows
    }

    /// Whether the file's menu has "Show whole file", and how it stands. Not once the file's text is here and its
    /// diff turns out to leave nothing out.
    private func showsWhole(_ file: Int) -> Bool? {
        guard document.shapes.indices.contains(file), document.shapes[file].hidesLines,
              document.texts[file] == nil || gapCounts[file] > 0
        else {
            return nil
        }
        return hidden.files.contains(document.files[file])
    }
}

extension DiffRows {
    /// Where a pending comment's card is drawn: its file, and its row among that file's. Nil for one with no row in
    /// this diff.
    func place(ofPending id: String) -> (file: Int, row: Int)? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        for (file, held) in files.enumerated() {
            if let row = held.rows.firstIndex(of: .draft(index)) {
                return (file, row)
            }
        }
        return nil
    }
}

extension [PRPendingComment] {
    /// The comment GitHub has refused since `before`: one that was there and not refused, and now says why it was.
    func newlyFailed(since before: [PRPendingComment]) -> PRPendingComment? {
        first { comment in
            comment.failure != nil && before.contains { $0.id == comment.id && $0.failure == nil }
        }
    }
}

extension DiffRows.Row {
    /// The line of the document a code row draws, whichever piece of it.
    var codeLine: Int? {
        switch self {
        case let .line(index), let .piece(index, _): index
        case .rest, .less, .thread, .draft, .note, .gap, .gapMore, .gapLess: nil
        }
    }

    /// A row that belongs to the line above it: a later piece, "Show full line" or "Show less".
    var continuesLine: Bool {
        switch self {
        case .piece, .rest, .less: true
        case .line, .thread, .draft, .note, .gap, .gapMore, .gapLess: false
        }
    }
}
