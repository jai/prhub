import DurableNetworking
import PRKitCore
import PRKitDesign
import SwiftUI

/// The key lines checked off at one head, as the Worker keeps them for each of the person's devices
/// (`GET …/key-lines-reviewed`, docs/api.md "Reviewed key lines"). A new commit starts the review again.
struct PRReviewedKeyLines: Codable, Equatable, Sendable {
    let head: String
    /// `PRKeyLines.Item.id`s: the same at every context, so a tick outlasts a change of context.
    var reviewed: Set<String>
}

/// `POST …/key-lines-reviewed`: one key line checked off at a head, or back on.
private struct PRKeyLineMark: Encodable, Sendable {
    let head: String
    let line: String
    let reviewed: Bool
}

/// Checking key lines off as reviewed: shown at once, then kept by the Worker so the phone and the Mac agree.
extension PRSession {
    private var reviewedPath: String {
        "prs/\(ref.repo)/\(ref.number)/key-lines-reviewed"
    }

    private func reviewedKey(_ head: String) -> InboxKey {
        InboxKey("reviewed-\(ref.repo)/\(ref.number)/\(head)")
    }

    private func keep(_ answer: PRReviewedKeyLines) {
        if let data = try? JSONEncoder().encode(answer) {
            model.keep(data, as: reviewedKey(answer.head))
        }
    }

    func isReviewed(_ item: PRKeyLines.Item) -> Bool {
        guard let reviewed = reviewedKeyLines, reviewed.head == content?.detail.head else {
            return false
        }
        return reviewed.reviewed.contains(item.id)
    }

    /// How many of the list's key lines are checked off.
    var reviewedKeyLineCount: Int {
        keyLineItems.filter(isReviewed).count
    }

    /// The ticks made on another device. Sample PRs keep theirs on the phone; an older Worker keeps none, and the
    /// ticks here stay as they are.
    func loadReviewedKeyLines() async {
        guard offersKeyLines, model.samples == nil, let head = content?.detail.head else {
            return
        }
        let marks = keyLineMarks
        // The last answer kept on this device stands in when the Worker can't be read: offline, the ticks still show.
        let key = reviewedKey(head)
        let answer: PRReviewedKeyLines?
        if let fresh = try? await model.client.read(reviewedPath, query: ["head": head], as: PRReviewedKeyLines.self) {
            answer = fresh
            keep(fresh)
        } else {
            answer = model.kept(key, as: PRReviewedKeyLines.self)
        }
        guard let answer, marks == keyLineMarks, answer.head == content?.detail.head, answer != reviewedKeyLines else {
            return
        }
        withAnimation(AppMotion.fold) { reviewedKeyLines = answer }
    }

    /// Ticks it here at once. A refusal takes the tick back and says why; a Worker without the route keeps it here.
    @discardableResult
    func setReviewed(_ isReviewed: Bool, _ item: PRKeyLines.Item) -> Task<Void, Never>? {
        guard let head = content?.detail.head else {
            return nil
        }
        keyLineMarks += 1
        notice = nil
        withAnimation(AppMotion.fold) { mark(item, isReviewed, at: head) }
        guard model.samples == nil else {
            return nil
        }
        let marks = keyLineMarks
        let body = PRKeyLineMark(head: head, line: item.id, reviewed: isReviewed)
        return Task {
            do {
                let answer = try await model.client.send(reviewedPath, body, as: PRReviewedKeyLines.self)
                if marks == keyLineMarks, answer.head == content?.detail.head {
                    reviewedKeyLines = answer
                }
                keep(answer)
            } catch PRWorkerError.notFound {
                return
            } catch {
                // Only this tick goes back, and only if nothing has changed it since.
                if self.isReviewed(item) == isReviewed {
                    withAnimation(AppMotion.fold) { mark(item, !isReviewed, at: head) }
                }
                withAnimation(AppMotion.fold) { notice = .failed(error.localizedDescription) }
            }
        }
    }

    private func mark(_ item: PRKeyLines.Item, _ isReviewed: Bool, at head: String) {
        var next = reviewedKeyLines.flatMap { $0.head == head ? $0 : nil }
            ?? PRReviewedKeyLines(head: head, reviewed: [])
        if isReviewed {
            next.reviewed.insert(item.id)
        } else {
            next.reviewed.remove(item.id)
        }
        reviewedKeyLines = next
    }
}
