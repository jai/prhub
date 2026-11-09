import PRKitCore
import PRKitDesign
import SwiftUI

/// What became of a write a screen sent: GitHub's answer, or the write saved on the phone and still going. A refusal
/// is thrown, in GitHub's words.
enum PRWriteOutcome {
    case posted(PullRequestDetail)
    case queued(PRQueueWait)

    var posted: PullRequestDetail? {
        guard case let .posted(detail) = self else {
            return nil
        }
        return detail
    }
}

/// Why a write saved on the phone hasn't had GitHub's answer yet.
enum PRQueueWait: Equatable, Sendable {
    /// Online: the Worker hasn't answered yet.
    case sending
    /// Offline: it goes when the phone is back online.
    case waitingForNetwork
}

/// What the phone refuses before anything is sent.
enum PRLocalRefusal: LocalizedError, Equatable {
    case sampleWrite
    case sampleAI
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .sampleWrite: "Sample PRs don't write to GitHub."
        case .sampleAI: "Sample PRs don't reach the model."
        case .notLoaded: "This PR hasn't loaded yet. Wait for it, then try again."
        }
    }
}

extension PRWrite {
    /// What Jai calls this write, for the words about it.
    var noun: String {
        switch self {
        case .comment, .line: "Your comment"
        case .reply: "Your reply"
        case .review: "Your review"
        case let .resolve(_, resolved): resolved ? "Resolving the thread" : "Reopening the thread"
        case let .viewed(_, _, viewed): viewed ? "Marking the file viewed" : "Unmarking the file"
        case .updateBranch: "Updating the branch"
        case .removeRequest: "Leaving this review"
        case .checkbox: "Your checkbox"
        case .editBody: "Your description edit"
        case .merge: "The merge"
        }
    }

    /// What Jai wrote, for a refusal that arrives after he has left the screen. Nil where there are no words to lose.
    var quote: String? {
        switch self {
        case let .comment(body), let .reply(_, body), let .line(_, _, _, body, _): body
        case let .review(_, body, _, _): body.isEmpty ? nil : body
        case .resolve, .viewed, .updateBranch, .removeRequest, .checkbox, .editBody, .merge: nil
        }
    }

    /// Said under the screen while it waits. A Viewed mark and leaving a review show their effect at once instead.
    var saysWhenQueued: Bool {
        switch self {
        case .viewed, .removeRequest: false
        default: true
        }
    }

    /// GitHub's refusal after the screen has gone: what was refused, with Jai's words, and why.
    func refusal(on ref: PullRequestRef, reason: String) -> String {
        let words = quote.map { " “\($0)”" } ?? ""
        return "GitHub refused \(noun.lowercased())\(words) on \(ref.repo)#\(ref.number): \(reason)"
    }
}

extension PRAskQuestion {
    /// The Worker's refusal after the Ask sheet has gone: the question, and why. Not GitHub's: it never sees one.
    func refusal(on ref: PullRequestRef, reason: String) -> String {
        "Your question “\(question)” to the AI on \(ref.repo)#\(ref.number) couldn't be sent: \(reason)"
    }
}

/// A line under a PR's actions after something happened: its words and its tone. One notice at a time.
enum PRNotice: Equatable {
    /// A sample PR's write: nothing left the phone.
    case sampleOnly
    /// A write saved on the phone and still going.
    case queued(noun: String, PRQueueWait)
    case failed(String)
    /// The rewrite found no ticket to write from.
    case rewroteWithoutTicket

    var words: String {
        switch self {
        case .sampleOnly: PRSampleSet.notice
        case let .queued(noun, .sending): "\(noun) is saved on this phone and on its way to GitHub."
        case let .queued(noun, .waitingForNetwork):
            "\(noun) is saved on this phone. It goes to GitHub when you're back online."
        case let .failed(reason): reason
        case .rewroteWithoutTicket: "Written without a ticket: none was found for this PR."
        }
    }

    var tone: Color {
        switch self {
        case .sampleOnly, .rewroteWithoutTicket: .secondary
        case .queued: .toneWaiting
        case .failed: .toneBad
        }
    }
}

/// A notice under a PR's actions, in its tone.
struct PRNoticeText: View {
    let notice: PRNotice

    var body: some View {
        Text(notice.words)
            .font(.appFootnote)
            .foregroundStyle(notice.tone)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("pr-notice")
            .transition(.fold)
    }
}
