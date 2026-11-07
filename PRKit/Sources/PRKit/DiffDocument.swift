import PRKitCore
import PRKitDesign
import Foundation

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

    /// Wider lines are drawn clipped, with a marker, and read in full on a tap: one minified line must not set the width
    /// of every row or be decoded on the main thread as the list scrolls.
    static let columns = 160

    /// How much a file changed, for its header.
    struct FileChange: Sendable, Equatable {
        var added = 0
        var removed = 0
    }

    let data: Data
    let lines: [Line]
    let files: [String]
    let fileChanges: [FileChange]

    init(data: Data) {
        self.data = data
        var parser = Parser()
        parser.parse(data)
        lines = parser.lines
        files = parser.files
        fileChanges = parser.fileChanges
    }

    func isClipped(_ line: Line) -> Bool {
        line.length > Self.columns
    }

    // swiftlint:disable optional_data_string_conversion
    // Lossy on purpose, here and in the parser: a line of a file that is not UTF-8 still shows.
    func text(of line: Line, limit: Int? = nil) -> String {
        let start = data.startIndex + line.start
        return String(decoding: data[start..<(start + min(line.length, limit ?? line.length))], as: UTF8.self)
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
                append(UnsafeRawBufferPointer(rebasing: bytes[start..<end]), start: start)
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
        if kind == .added {
            fileChanges[fileChanges.count - 1].added += 1
        } else if kind == .removed {
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
