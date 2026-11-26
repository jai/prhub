import Foundation
import PRKitCore
import PRKitDesign

/// A unified diff as a table of lines over its bytes. A line is decoded when it is drawn, so the cost of opening a diff
/// is one pass over the bytes, whatever its size.
struct DiffDocument: Sendable {
    enum Kind: UInt8, Sendable {
        case file, meta, hunk, added, removed, context
    }

    struct Line: Sendable, Equatable {
        let start: Int
        let length: Int
        let kind: Kind
        /// Into `files`.
        let file: Int
        /// In the old and new versions of the file; 0 for a line that has none there.
        let oldLine: Int
        let newLine: Int
        /// A line of the file's own text, which the diff left out (`showing`): its bytes are in `texts`, with no
        /// space before them as a diff's unchanged line has.
        var isOutsideDiff = false
    }

    /// One `@@ -old,count +new,count @@` of a file. The lines a diff leaves out are what lies between these.
    struct Hunk: Sendable, Equatable {
        let file: Int
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        /// `\ No newline at end of file` follows a line of it: the file ends in this hunk.
        var reachesEnd = false

        /// The first line it shows of the new file. A hunk of no lines there names the line before it.
        var newFirst: Int {
            newCount == 0 ? newStart + 1 : newStart
        }

        var oldFirst: Int {
            oldCount == 0 ? oldStart + 1 : oldStart
        }

        /// The first line after it, in the new file and in the old.
        var newEnd: Int {
            newFirst + newCount
        }

        var oldEnd: Int {
            oldFirst + oldCount
        }
    }

    /// What a file's own header lines say of it, and which hunks are its own.
    struct FileShape: Sendable, Equatable {
        /// In `hunks`.
        var hunks: Range<Int>
        var isBinary = false
        var isDeleted = false
        var isNew = false

        /// Whether the file may have lines its diff does not show. A new or a deleted file is whole in its diff, and
        /// a binary one has no lines.
        var hidesLines: Bool {
            !isBinary && !isDeleted && !isNew
        }
    }

    /// A file's text at the PR's head, read to show what its diff leaves out. Its lines follow the diff's own in
    /// `lines`: line `n` of the file is at `base + n - 1`.
    struct FileText: Sendable {
        let data: Data
        let base: Int
        let count: Int
    }

    /// Where lines scroll sideways and don't wrap, wider lines are drawn clipped, with a marker: one minified line must
    /// not set the width of every row or be decoded on the main thread as the list scrolls.
    static let columns = 160

    /// Where lines wrap, a line longer than this is drawn as several rows, a piece each: a minified file is one line of
    /// a megabyte, and one row of it would be a picture hundreds of screens tall. A kilobyte is about half a phone's
    /// screen of wrapped code, and a few screens at the largest text.
    static let pieceBytes = 1024
    /// How far back from a piece's end its break is looked for: a space first, then a comma or a semicolon, so a
    /// piece ends where a wrapped line would.
    private static let pieceBreakReach = 256
    /// Prose and code up to this long are shown whole however many rows they take: a README's paragraph written as
    /// one line is a few kilobytes at most, and is there to be read. Past it, and for a minified line past one piece,
    /// the line's start is shown (`DiffWrap.shownRows`) over "Show full line".
    static let wholeBytes = 4096

    /// Whether a long line opens cut, its start over "Show full line": it is minified, or longer than anything read.
    /// Those are the lines drawn in pieces.
    func opensCut(_ index: Int) -> Bool {
        pieceCount(ofLine: index) > 1
    }

    /// How much a file changed, for its header.
    struct FileChange: Sendable, Equatable {
        var added = 0
        var removed = 0
    }

    let data: Data
    /// The diff's own lines, then the lines of each file text read since (`showing`).
    private(set) var lines: [Line]
    let files: [String]
    let fileChanges: [FileChange]
    /// Every hunk, in the diff's order, and each file's own: read in the one pass that reads the lines.
    let hunks: [Hunk]
    let shapes: [FileShape]
    /// How many of `lines` are the diff's own.
    let diffLineCount: Int
    private(set) var lineNumberDigits: Int
    /// Where each piece of a long line starts, from the line's first byte, by the line's index. A line of one piece,
    /// nearly every line, has no entry.
    private(set) var pieces: [Int: [Int]]
    /// The files' texts read so far, by the file's index.
    private(set) var texts: [Int: FileText] = [:]

    init(data: Data) {
        self.data = data
        var parser = Parser()
        parser.parse(data)
        lines = parser.lines
        files = parser.files
        fileChanges = parser.fileChanges
        hunks = parser.hunks
        shapes = parser.shapes
        diffLineCount = parser.lines.count
        let largestLine = parser.lines.reduce(0) { max($0, $1.oldLine, $1.newLine) }
        lineNumberDigits = max(3, String(largestLine).count)
        pieces = Self.pieces(of: parser.lines[...], in: data)
    }

    func pieceCount(ofLine index: Int) -> Int {
        pieces[index]?.count ?? 1
    }

    /// One piece of a line: the whole line when it has one.
    func text(ofLine index: Int, piece: Int) -> String {
        let line = lines[index]
        guard let starts = pieces[index], starts.indices.contains(piece) else {
            return text(of: line)
        }
        let end = piece + 1 < starts.count ? starts[piece + 1] : line.length
        return decoded(line, from: starts[piece], count: end - starts[piece])
    }

    /// A piece's bytes as drawn: a line from a file's text is drawn after a space, as the diff's unchanged lines are.
    func byteCount(ofLine index: Int, piece: Int) -> Int {
        let line = lines[index]
        let space = line.isOutsideDiff && piece == 0 ? 1 : 0
        guard let starts = pieces[index], starts.indices.contains(piece) else {
            return line.length + space
        }
        return (piece + 1 < starts.count ? starts[piece + 1] : line.length) - starts[piece] + space
    }

    /// A piece's own bytes, where they are: from `start` in `source(of:)`.
    private func span(ofLine index: Int, piece: Int) -> (start: Int, count: Int) {
        let line = lines[index]
        guard let starts = pieces[index], starts.indices.contains(piece) else {
            return (line.start, line.length)
        }
        let end = piece + 1 < starts.count ? starts[piece + 1] : line.length
        return (line.start + starts[piece], end - starts[piece])
    }

    /// The bytes a line is in: the diff's, or its file's text.
    private func source(of line: Line) -> Data {
        line.isOutsideDiff ? texts[line.file]?.data ?? Data() : data
    }

    /// Whether a piece is plain ASCII with no tab: every character is then one column wide.
    func isPlain(line index: Int, piece: Int) -> Bool {
        let (start, count) = span(ofLine: index, piece: piece)
        return source(of: lines[index]).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for position in start ..< start + count where bytes[position] >= 0x80 || bytes[position] == 0x09 {
                return false
            }
            return true
        }
    }

    /// Whether a piece has hardly a space in it, as minified code and data do: fewer than one in sixteen characters.
    /// Broken between words it would leave most rows part empty, so it is broken wherever the row ends.
    func isMinified(line index: Int, piece: Int) -> Bool {
        let (start, count) = span(ofLine: index, piece: piece)
        guard count >= Self.minifiedAtLeast else {
            return false
        }
        return source(of: lines[index]).withUnsafeBytes { Self.isMinified($0, from: start, count: count) }
    }

    private static func isMinified(_ bytes: UnsafeRawBufferPointer, from start: Int, count: Int) -> Bool {
        var spaces = 0
        for position in start ..< start + count where bytes[position] == 0x20 {
            spaces += 1
        }
        return spaces * minifiedSpacing < count
    }

    private static let minifiedAtLeast = 64
    private static let minifiedSpacing = 16

    /// The column a line's code starts at, after its `+` or `-` and its indentation; a tab goes to the next fourth
    /// column, as the wrapped code draws it. 0 for a header.
    func indentColumns(of line: Line) -> Int {
        guard line.kind == .added || line.kind == .removed || line.kind == .context, line.length > 0 else {
            return 0
        }
        // A diff's line starts with its `+`, `-` or space; a file's own line is drawn after a space it does not hold.
        let first = line.isOutsideDiff ? line.start : line.start + 1
        return source(of: line).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var column = 1
            for position in first ..< max(first, line.start + min(line.length, Self.pieceBreakReach)) {
                if bytes[position] == 0x20 {
                    column += 1
                } else if bytes[position] == 0x09 {
                    column = (column / Self.tabColumns + 1) * Self.tabColumns
                } else {
                    break
                }
            }
            return column
        }
    }

    static let tabColumns = 4

    /// By the line's index in `lines`, which `lines` here is a run of.
    private static func pieces(of lines: ArraySlice<Line>, in data: Data) -> [Int: [Int]] {
        var pieces: [Int: [Int]] = [:]
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in lines.indices where lines[index].length > pieceBytes {
                let line = lines[index]
                // A paragraph is one row, read with no seam in it: only what is cut is drawn in pieces.
                if line.length <= wholeBytes, !isMinified(bytes, from: line.start, count: line.length) {
                    continue
                }
                var starts = [0]
                var start = 0
                while line.length - start > pieceBytes {
                    start = pieceEnd(from: start, of: line, in: bytes)
                    starts.append(start)
                }
                pieces[index] = starts
            }
        }
        return pieces
    }

    /// Where the piece from `start` ends: after the last space in its last stretch, else after the last comma or
    /// semicolon, else at `pieceBytes`, moved back off the middle of a character.
    private static func pieceEnd(from start: Int, of line: Line, in bytes: UnsafeRawBufferPointer) -> Int {
        let limit = start + pieceBytes
        var mark: Int?
        var position = limit
        while position > limit - pieceBreakReach {
            let byte = bytes[line.start + position - 1]
            if byte == 0x20 {
                return position
            }
            if mark == nil, byte == 0x2C || byte == 0x3B {
                mark = position
            }
            position -= 1
        }
        if let mark {
            return mark
        }
        var end = limit
        while end > start + 1, bytes[line.start + end] & 0xC0 == 0x80 {
            end -= 1
        }
        return end
    }

    func isClipped(_ line: Line) -> Bool {
        line.length > Self.columns
    }

    // swiftlint:disable optional_data_string_conversion
    // Lossy on purpose, here and in the parser: a line of a file that is not UTF-8 still shows.
    func text(of line: Line, limit: Int? = nil) -> String {
        decoded(line, from: 0, count: min(line.length, limit ?? line.length))
    }

    /// `count` bytes of a line from `offset` in it. A file's own line starts with the space a diff gives an unchanged
    /// line, so its code stands where theirs does.
    private func decoded(_ line: Line, from offset: Int, count: Int) -> String {
        let source = source(of: line)
        let start = source.startIndex + line.start + offset
        let text = String(decoding: source[start ..< start + count], as: UTF8.self)
        return line.isOutsideDiff && offset == 0 ? " " + text : text
    }
}

// MARK: - The lines a diff leaves out

extension DiffDocument {
    /// This diff with a file's text at the PR's head, so the lines its hunks leave out can be rows. The diff is not
    /// read again: the text's lines are found in one pass over its own bytes and follow the diff's in `lines`, each
    /// numbered in the new file by its place and in the old by what the hunks around it say. A line ends at its
    /// newline, a `\r` before it left out. Unchanged if the file is not in this diff or its text is here already.
    func showing(_ text: Data, forFile file: Int) -> DiffDocument {
        guard files.indices.contains(file), shapes.indices.contains(file), texts[file] == nil else {
            return self
        }
        var next = self
        let base = lines.count
        let own = hunks[shapes[file].hunks]
        var hunk = own.startIndex
        next.lines.reserveCapacity(base + text.count / 32)
        text.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            var number = 1
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A {
                    end += 1
                }
                let length = end > start && bytes[end - 1] == 0x0D ? end - start - 1 : end - start
                while hunk < own.endIndex, number >= own[hunk].newEnd {
                    hunk += 1
                }
                next.lines.append(Line(
                    start: start, length: length, kind: .context, file: file,
                    oldLine: Self.oldLine(ofNew: number, before: hunk, of: own), newLine: number, isOutsideDiff: true
                ))
                number += 1
                start = end + 1
            }
        }
        let count = next.lines.count - base
        next.texts[file] = FileText(data: text, base: base, count: count)
        next.lineNumberDigits = max(lineNumberDigits, String(count).count)
        next.pieces.merge(Self.pieces(of: next.lines[base...], in: text)) { _, new in new }
        return next
    }

    /// The old file's number for line `number` of the new one, which lies before hunk `hunk` of its file's `own`
    /// (after them all, at their end): unchanged lines keep their distance from the hunk beside them. 0 for a line
    /// inside a hunk, which the diff itself shows.
    private static func oldLine(ofNew number: Int, before hunk: Int, of own: ArraySlice<Hunk>) -> Int {
        if hunk < own.endIndex {
            return number < own[hunk].newFirst ? number - (own[hunk].newFirst - own[hunk].oldFirst) : 0
        }
        return own.last.map { number - ($0.newEnd - $0.oldEnd) } ?? number
    }

    /// `showing(_:forFile:)` for each text whose file is in this diff, by path. In the paths' order, so the same
    /// texts give the same document.
    func showing(_ texts: [String: Data]) -> DiffDocument {
        var next = self
        for path in texts.keys.sorted() {
            if let file = files.firstIndex(of: path), let text = texts[path] {
                next = next.showing(text, forFile: file)
            }
        }
        return next
    }
}

private struct Parser {
    var lines: [DiffDocument.Line] = []
    var files: [String] = []
    var fileChanges: [DiffDocument.FileChange] = []
    var hunks: [DiffDocument.Hunk] = []
    var shapes: [DiffDocument.FileShape] = []
    private var inFileHeader = false
    private var removedPath = ""
    private var oldLine = 0
    private var newLine = 0

    mutating func parse(_ data: Data) {
        lines.reserveCapacity(data.count / 32)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A {
                    end += 1
                }
                append(UnsafeRawBufferPointer(rebasing: bytes[start ..< end]), start: start)
                start = end + 1
            }
        }
    }

    private mutating func append(_ line: UnsafeRawBufferPointer, start: Int) {
        let kind = kind(of: line)
        var old = 0
        var new = 0
        if kind == .context || kind == .removed {
            old = oldLine
            oldLine += 1
        }
        if kind == .context || kind == .added {
            new = newLine
            newLine += 1
        }
        if kind == .added, !fileChanges.isEmpty {
            fileChanges[fileChanges.count - 1].added += 1
        } else if kind == .removed, !fileChanges.isEmpty {
            fileChanges[fileChanges.count - 1].removed += 1
        }
        lines.append(DiffDocument.Line(
            start: start, length: line.count, kind: kind, file: max(files.count - 1, 0), oldLine: old, newLine: new
        ))
    }

    /// `+++` and `---` are file names only before a file's first hunk; inside a hunk they are a changed line.
    private mutating func kind(of line: UnsafeRawBufferPointer) -> DiffDocument.Kind {
        if line.starts(with: Array("diff ".utf8)) {
            inFileHeader = true
            files.append(pathInDiffLine(line))
            fileChanges.append(DiffDocument.FileChange())
            shapes.append(DiffDocument.FileShape(hunks: hunks.count ..< hunks.count))
            return .file
        }
        if line.starts(with: Array("@@".utf8)) {
            inFileHeader = false
            readHunkStart(line)
            return .hunk
        }
        if inFileHeader {
            readPath(line)
            return .meta
        }
        switch line.first {
        case UInt8(ascii: "+"): return .added
        case UInt8(ascii: "-"): return .removed
        case UInt8(ascii: "\\"):
            // `\ No newline at end of file`: said only of a file's last line.
            if !hunks.isEmpty {
                hunks[hunks.count - 1].reachesEnd = true
            }
            return .meta
        default: return .context
        }
    }

    /// `diff --git a/path b/path`: all a renamed or binary file has. `+++` replaces it where there is one.
    private func pathInDiffLine(_ line: UnsafeRawBufferPointer) -> String {
        let text = String(decoding: line, as: UTF8.self)
        return text.range(of: " b/", options: .backwards).map { String(text[$0.upperBound...]) } ?? text
    }

    /// `+++ b/path`, or `--- a/path` for a deleted file, whose new side is /dev/null. The header also says when the
    /// file is new, deleted or binary: such a file has no lines its diff leaves out.
    private mutating func readPath(_ line: UnsafeRawBufferPointer) {
        if line.starts(with: Array("--- a/".utf8)) {
            removedPath = String(decoding: line.dropFirst(6), as: UTF8.self)
            files[files.count - 1] = removedPath
        } else if line.starts(with: Array("+++ b/".utf8)) {
            files[files.count - 1] = String(decoding: line.dropFirst(6), as: UTF8.self)
        } else if line.starts(with: Array("+++ /dev/null".utf8)) || line.starts(with: Array("deleted file mode".utf8)) {
            shapes[shapes.count - 1].isDeleted = true
        } else if line.starts(with: Array("--- /dev/null".utf8)) || line.starts(with: Array("new file mode".utf8)) {
            shapes[shapes.count - 1].isNew = true
        } else if line.starts(with: Array("Binary files ".utf8)) || line.starts(with: Array("GIT binary patch".utf8)) {
            shapes[shapes.count - 1].isBinary = true
        }
    }

    /// `@@ -old,count +new,count @@`; a count left out is 1. Every `@@` line is a hunk, read or not, so the hunks
    /// are counted as their rows are.
    private mutating func readHunkStart(_ line: UnsafeRawBufferPointer) {
        let fields = String(decoding: line.prefix(64), as: UTF8.self).split(separator: " ")
        var old = (start: 0, count: 0)
        var new = (start: 0, count: 0)
        if fields.count >= 3 {
            old = Self.range(fields[1])
            new = Self.range(fields[2])
            oldLine = old.start
            newLine = new.start
        }
        hunks.append(DiffDocument.Hunk(
            file: max(files.count - 1, 0), oldStart: old.start, oldCount: old.count, newStart: new.start,
            newCount: new.count
        ))
        if !shapes.isEmpty {
            shapes[shapes.count - 1].hunks = shapes[shapes.count - 1].hunks.lowerBound ..< hunks.count
        }
    }

    /// `-10,2` or `+10`: where a hunk starts in a file and how many lines of it it shows.
    private static func range(_ field: Substring) -> (start: Int, count: Int) {
        let numbers = field.dropFirst().split(separator: ",", maxSplits: 1)
        return (numbers.first.flatMap { Int($0) } ?? 0, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
    }
}

// swiftlint:enable optional_data_string_conversion
