import PRKitCore
import PRKitDesign
import SwiftUI

/// The comments of the review not submitted yet, as the PR's screens ask for them. With a Worker that reads pending
/// reviews, GitHub holds the review and `PRPendingSync` keeps the device in step with it; with an older one the
/// comments wait on this device and go with the review, as they always did.
extension PRSession: PRPendingFollower {
    /// The PR's review lives on GitHub: its detail carries the `pendingReview` key.
    var usesPendingReview: Bool {
        content?.detail.pendingReview.isSupported == true
    }

    /// What `text` sent to `target` asks of GitHub. With a pending review there, a review is its submit: the comments
    /// are GitHub's already, so only the verdict and the words go.
    func write(
        _ text: String, to target: PRComposerTarget, in detail: PullRequestDetail, with drafts: [PRDraftComment]
    ) -> PRWrite {
        if usesPendingReview, case let .review(event) = target {
            return .pendingSubmit(event, body: text)
        }
        return target.write(body: text, head: detail.head, drafts: drafts, description: detail.body)
    }

    /// `PRPendingSync` changed the list: an edit, GitHub's answer or its refusal, from this screen or any other.
    func pendingChanged(detail: PullRequestDetail?) {
        rebuildRows(detail: detail, isNoted: true)
    }

    /// How many pending comments a review sent now carries: every one but those GitHub refused to take.
    var pendingGoing: Int {
        pending.count { $0.goesWithReview }
    }

    /// Comments of this device's that GitHub refused: no review carries them until they are tried again.
    var pendingNotGoing: Int {
        pending.count { !$0.goesWithReview }
    }

    /// Changes to GitHub's comments that GitHub refused: the review goes with what GitHub has.
    var pendingChangesRefused: Int {
        pending.count { $0.goesWithReview && $0.failure != nil }
    }

    /// The pending replies to a posted thread, for under its card.
    func pendingReplies(to thread: String) -> [PRPendingComment] {
        pending.filter { $0.thread == thread }
    }

    /// The pending comments with no place of their own on the PR's page or under a line of its diff: on a whole file,
    /// on a line a newer commit took away or this diff does not show, or every one where GitHub sent no diff. The
    /// page lists them, so each is seen, changed or deleted somewhere. A reply sits under its thread instead.
    var pendingOffDiff: [PRPendingComment] {
        var placed: Set<String> = []
        if case let .document(_, rows) = content?.diff {
            placed = rows.placed
        }
        let threads = Set(content?.detail.reviewThreads.nodes.map(\.id) ?? [])
        return pending.filter { comment in
            if let thread = comment.thread, threads.contains(thread) {
                return false
            }
            return !placed.contains(comment.id)
        }
    }

    /// A comment for the review, from anywhere: saved on this device and shown at once as pending, then sent to
    /// GitHub's pending review. On a Worker without pending reviews it waits here for its review.
    func addPendingComment(body: String, path: String, line: Int, side: PRDiffSide) {
        addDrafts([PRDraftComment(id: UUID(), path: path, line: line, side: side, body: body)])
    }

    func addDraft(_ text: String, on target: PRComposerTarget) {
        guard case let .line(path, line, side) = target else {
            return
        }
        discardText(for: target)
        addPendingComment(body: text, path: path, line: line, side: side)
    }

    /// Line comments from elsewhere (Ask AI's drafted review), after his own.
    func addDrafts(_ more: [PRDraftComment]) {
        if usesPendingReview {
            model.pendingSync.add(more, to: ref)
        } else {
            setDrafts(drafts + more)
        }
    }

    /// The words of the pending comment being changed, while its box is open; nil while it is not.
    func editText(for comment: PRPendingComment) -> Binding<String?> {
        let key = "pending:\(comment.id)"
        return Binding { self.writing[key] } set: { self.writing[key] = $0 }
    }

    /// New words for a pending comment, shown at once.
    func editPending(_ comment: PRPendingComment, body: String) {
        withAnimation(AppMotion.fold) { editText(for: comment).wrappedValue = nil }
        if usesPendingReview {
            Task { await model.pendingSync.edit(comment, body: body, on: ref) }
        } else if case let .device(draft) = comment.origin {
            setDrafts(drafts.map { kept in
                var kept = kept
                if kept.id == draft.id {
                    kept.body = body
                }
                return kept
            })
        }
    }

    func removePending(_ comment: PRPendingComment) {
        if usesPendingReview {
            Task { await model.pendingSync.delete(comment, on: ref) }
        } else if case let .device(draft) = comment.origin {
            setDrafts(drafts.filter { $0.id != draft.id })
        }
    }

    /// A refused comment or change, sent again.
    func retryPending(_ comment: PRPendingComment) {
        model.pendingSync.retry(comment, on: ref)
    }

    /// A comment GitHub refused on its line, sent again as a comment on its file.
    func addPendingToFile(_ comment: PRPendingComment) {
        model.pendingSync.addToFile(comment, on: ref)
    }

    /// A review from its box with the PR's review on GitHub: what is still unsent goes first, then the submit with
    /// the verdict and the words (`PRsModel.submitReview`). "Comment now" on a line adds that comment and submits. A
    /// refusal gives the words back to the box; the comments are on GitHub or on this device either way.
    func submitPendingReview(_ text: String, to target: PRComposerTarget, in detail: PullRequestDetail) {
        var isLine = false
        var write = write(text, to: target, in: detail, with: [])
        if case let .line(path, line, side) = target {
            isLine = true
            addPendingComment(body: text, path: path, line: line, side: side)
            write = .pendingSubmit(.comment, body: "")
        }
        discardText(for: target)
        notice = nil
        model.submitReview(write, to: ref, drafts: [], head: detail.head, answer: target.answer) { [weak self] phase, detail in
            guard let self else {
                return
            }
            switch phase {
            case .done:
                discardText(for: target)
                rebuildRows(detail: detail)
                withAnimation(AppMotion.fold) { notice = model.writeNotice }
            case .failed:
                // A line's comment is under its line already, pending: its words are not lost.
                if !isLine {
                    writing[target.key] = text
                }
            case .sending:
                discardText(for: target)
            case .waitingForNetwork:
                break
            }
        }
    }
}
