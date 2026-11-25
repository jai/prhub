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
    let lines: [Line]
    let files: [String]
    let fileChanges: [FileChange]
    let lineNumberDigits: Int
    /// Where each piece of a long line starts, from the line's first byte, by the line's index. A line of one piece,
    /// nearly every line, has no entry.
    let pieces: [Int: [Int]]

    init(data: Data) {
        self.data = data
        var parser = Parser()
        parser.parse(data)
        lines = parser.lines
        files = parser.files
        fileChanges = parser.fileChanges
        let largestLine = parser.lines.reduce(0) { max($0, $1.oldLine, $1.newLine) }
        lineNumberDigits = max(3, String(largestLine).count)
        pieces = Self.pieces(of: parser.lines, in: data)
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
        return decoded(line.start + starts[piece], count: end - starts[piece])
    }

    func byteCount(ofLine index: Int, piece: Int) -> Int {
        let line = lines[index]
        guard let starts = pieces[index], starts.indices.contains(piece) else {
            return line.length
        }
        return (piece + 1 < starts.count ? starts[piece + 1] : line.length) - starts[piece]
    }

    /// Whether a piece is plain ASCII with no tab: every character is then one column wide.
    func isPlain(line index: Int, piece: Int) -> Bool {
        let line = lines[index]
        let offset = pieces[index].map { $0.indices.contains(piece) ? $0[piece] : 0 } ?? 0
        let count = byteCount(ofLine: index, piece: piece)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let start = line.start + offset
            for position in start ..< start + count where bytes[position] >= 0x80 || bytes[position] == 0x09 {
                return false
            }
            return true
        }
    }

    /// Whether a piece has hardly a space in it, as minified code and data do: fewer than one in sixteen characters.
    /// Broken between words it would leave most rows part empty, so it is broken wherever the row ends.
    func isMinified(line index: Int, piece: Int) -> Bool {
        let line = lines[index]
        let offset = pieces[index].map { $0.indices.contains(piece) ? $0[piece] : 0 } ?? 0
        let count = byteCount(ofLine: index, piece: piece)
        guard count >= Self.minifiedAtLeast else {
            return false
        }
        return data.withUnsafeBytes { Self.isMinified($0, from: line.start + offset, count: count) }
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
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var column = 1
            for position in line.start + 1 ..< line.start + min(line.length, Self.pieceBreakReach) {
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

    private static func pieces(of lines: [Line], in data: Data) -> [Int: [Int]] {
        var pieces: [Int: [Int]] = [:]
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for (index, line) in lines.enumerated() where line.length > pieceBytes {
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
        decoded(line.start, count: min(line.length, limit ?? line.length))
    }

    private func decoded(_ offset: Int, count: Int) -> String {
        let start = data.startIndex + offset
        return String(decoding: data[start ..< start + count], as: UTF8.self)
    }
}

private struct Parser {
    var lines: [DiffDocument.Line] = []
    var files: [String] = []
    var fileChanges: [DiffDocument.FileChange] = []
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
        case UInt8(ascii: "\\"): return .meta
        default: return .context
        }
    }

    /// `diff --git a/path b/path`: all a renamed or binary file has. `+++` replaces it where there is one.
    private func pathInDiffLine(_ line: UnsafeRawBufferPointer) -> String {
        let text = String(decoding: line, as: UTF8.self)
        return text.range(of: " b/", options: .backwards).map { String(text[$0.upperBound...]) } ?? text
    }

    /// `+++ b/path`, or `--- a/path` for a deleted file, whose new side is /dev/null.
    private mutating func readPath(_ line: UnsafeRawBufferPointer) {
        if line.starts(with: Array("--- a/".utf8)) {
            removedPath = String(decoding: line.dropFirst(6), as: UTF8.self)
            files[files.count - 1] = removedPath
        } else if line.starts(with: Array("+++ b/".utf8)) {
            files[files.count - 1] = String(decoding: line.dropFirst(6), as: UTF8.self)
        }
    }

    /// `@@ -old,count +new,count @@`.
    private mutating func readHunkStart(_ line: UnsafeRawBufferPointer) {
        let fields = String(decoding: line.prefix(64), as: UTF8.self).split(separator: " ")
        guard fields.count >= 3 else {
            return
        }
        oldLine = Int(fields[1].dropFirst().prefix { $0 != "," }) ?? 0
        newLine = Int(fields[2].dropFirst().prefix { $0 != "," }) ?? 0
    }
}

// swiftlint:enable optional_data_string_conversion
