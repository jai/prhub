import Foundation
import PRKitCore
import PRKitDesign

/// The lines of a file its diff leaves out: GitHub's diff shows three unchanged lines around each change. Where they
/// lie comes from the diff's hunks; what they say comes from the file's text at the PR's head, read when the reader
/// first asks for one (`PRSession+Hidden.swift`). An unchanged line is the same in the old file and the new.
extension DiffRows {
    /// A gap longer than this opens as its first and last `gapEdge` lines round "Show N more lines": no row is laid
    /// out for a line nobody asked for, as with a very long line's pieces. 2,000 lines are some sixty phone screens.
    static let gapLimit = 2000
    /// A screenful or so at each end of a long gap: the lines next to the change above it and the one below.
    static let gapEdge = 200

    /// A gap whatever the diff's order: which the reader opened outlasts a rebuild of the rows. `first` is its first
    /// line in the new file.
    struct GapID: Hashable, Sendable {
        let path: String
        let first: Int
    }

    struct Gap: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case closed
            /// The file's text is being read.
            case loading
            /// The text could not be read, and why, in words for the reader.
            case failed(String)
            case open
        }

        /// Into the diff's files.
        let file: Int
        /// Its place among its file's gaps, from 0.
        let ordinal: Int
        let id: GapID
        /// Its last line in the new file; nil while only the file's text can say where the file ends.
        let last: Int?
        let state: State
        /// The lines of a long open gap that wait behind "Show N more lines".
        var more = 0

        /// How many lines it is, where that is known.
        var count: Int? {
            last.map { $0 - id.first + 1 }
        }

        /// "Show 12 hidden lines"; "Show hidden lines" after a file's last hunk, until its text says how many.
        var title: String {
            guard let count else {
                return "Show hidden lines"
            }
            return count == 1 ? "Show 1 hidden line" : "Show \(count.formatted()) hidden lines"
        }

        var moreTitle: String {
            "Show \(more.formatted()) more lines"
        }

        static let lessTitle = DiffWrap.lessTitle
        static let retryTitle = "Try again"

        /// What a test and VoiceOver find its rows by: `diff-gap-<file>-<n>`, and `-less-` and `-more-` likewise.
        func identifier(_ part: String? = nil) -> String {
            "diff-gap-\(part.map { "\($0)-" } ?? "")\(file)-\(ordinal)"
        }
    }

    /// Which of the lines the diff leaves out are shown, by path so it outlasts a sync, and how each file's read
    /// stands.
    struct Hidden: Sendable, Equatable {
        /// A read that failed: the gap it was asked from, or the file's first when its menu asked, and why.
        struct Failure: Sendable, Equatable {
            /// The gap's first line; nil when "Show whole file" asked.
            let first: Int?
            let words: String
        }

        /// The gaps opened one by one.
        var gaps: Set<GapID> = []
        /// The files shown whole: every gap of theirs is open.
        var files: Set<String> = []
        /// The long gaps whose every line is shown.
        var full: Set<GapID> = []
        /// The files whose text is being read.
        var loading: Set<String> = []
        var failures: [String: Failure] = [:]

        /// How a gap that is not open stands.
        func state(of id: GapID, ordinal: Int) -> Gap.State {
            if loading.contains(id.path) {
                return .loading
            }
            if let failure = failures[id.path], failure.first == id.first || (failure.first == nil && ordinal == 0) {
                return .failed(failure.words)
            }
            return .closed
        }
    }
}

extension DiffRows.File {
    static let wholeTitle = "Show whole file"

    /// `diff-whole-file-<path>`: the menu's item.
    var wholeIdentifier: String {
        "diff-whole-file-\(path)"
    }
}
