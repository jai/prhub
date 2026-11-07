import PRKitCore
import PRKitDesign
import Foundation

/// Where a comment goes, before it has words.
enum PRComposerTarget: Sendable {
    case comment
    case review(PRReviewEvent)
    case line(path: String, line: Int, side: PRDiffSide)
    case reply(thread: PullRequestDetail.Thread)
    case description

    /// The line's place in its file; nil for a line GitHub takes no comment on.
    init?(_ document: DiffDocument, line: DiffDocument.Line) {
        guard document.files.indices.contains(line.file), line.newLine > 0 || line.oldLine > 0 else {
            return nil
        }
        let isNewSide = line.newLine > 0
        self = .line(
            path: document.files[line.file], line: isNewSide ? line.newLine : line.oldLine,
            side: isNewSide ? .right : .left
        )
    }

    /// Where half-written words wait: one box's text for each place a comment can go.
    var key: String {
        switch self {
        case .comment: "comment"
        case let .review(event): "review:\(event.rawValue)"
        case let .line(path, line, side): "line:\(side.rawValue):\(line):\(path)"
        case let .reply(thread): "reply:\(thread.id)"
        case .description: "description"
        }
    }

    /// What this says as Jai's answer to the PR, in the Worker's words. Nil for what isn't an answer, such as a reply.
    var answer: String? {
        switch self {
        case .comment, .review(.comment): "commented"
        case .review(.approve): "approved"
        case .review(.requestChanges): "changes_requested"
        case .line, .reply, .description: nil
        }
    }

    func write(body: String, head: String, drafts: [PRDraftComment], description: String? = nil) -> PRWrite {
        switch self {
        case .comment: .comment(body: body)
        case let .review(event): .review(event, body: body, commit: head, comments: drafts)
        case let .line(path, line, side): .line(path: path, line: line, side: side, body: body, commit: head)
        case let .reply(thread): .reply(thread: thread.id, body: body)
        case .description: .editBody(body, base: description)
        }
    }
}
