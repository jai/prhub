import PRKitCore
import PRKitDesign
import SwiftUI

/// What a review button opens in place: Approve, Request changes or Comment. The PR's page and its diff send a review
/// through these, the one way.
enum PRReviewAction {
    case approve, requestChanges, comment

    var title: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        case .comment: "Comment"
        }
    }

    var icon: AppIcon {
        switch self {
        case .approve: .reviewApproved
        case .requestChanges: .reviewChangesRequested
        case .comment: .reviewCommented
        }
    }

    /// Approve is the good tone and Request changes the bad one; Comment keeps the accent.
    var tone: Color? {
        switch self {
        case .approve: Color.toneGood
        case .requestChanges: Color.toneBad
        case .comment: nil
        }
    }

    var identifier: String {
        switch self {
        case .approve: "pr-review-approve"
        case .requestChanges: "pr-review-request-changes"
        case .comment: "pr-review-comment"
        }
    }

    var target: PRComposerTarget {
        switch self {
        case .approve: .review(.approve)
        case .requestChanges: .review(.requestChanges)
        case .comment: .comment
        }
    }

    /// With comments waiting, a plain comment is the review that carries them.
    func target(hasDrafts: Bool) -> PRComposerTarget {
        self == .comment && hasDrafts ? .review(.comment) : target
    }
}

/// The review buttons as one bar across the width they are given, each the same width. When one's words don't fit,
/// all of them show their icons instead, together; each keeps its words as its accessibility label. The author can only
/// comment on their own PR.
struct PRReviewBar: View {
    let isAuthor: Bool
    let open: (PRReviewAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showsWords: true)
            bar(showsWords: false)
        }
    }

    /// No `ForEach`: `ViewThatFits` makes a `ForEach`'s views while it lays out, which iOS can do on SwiftUI's render
    /// thread, and the main-actor closure traps there.
    private func bar(showsWords: Bool) -> some View {
        EqualWidths(spacing: Space.sm) {
            if !isAuthor {
                button(.approve, showsWords: showsWords)
                button(.requestChanges, showsWords: showsWords)
            }
            button(.comment, showsWords: showsWords)
        }
    }

    private func button(_ action: PRReviewAction, showsWords: Bool) -> some View {
        Button { open(action) } label: {
            Group {
                if showsWords {
                    Text(action.title)
                        .lineLimit(1)
                } else {
                    Image(action.icon)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PRButtonStyle(action == .approve ? .primary : .secondary, inset: PRStyle.barButtonInset))
        .tint(action.tone)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.identifier)
    }
}

/// The review's place on a PR's page and on its diff: what goes with it, the bar, and what GitHub said.
struct PRReviewActions: View {
    let session: PRSession
    let isAuthor: Bool
    @Binding var action: PRReviewAction?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            PRPendingComments(count: session.drafts.count)
            PRReviewBar(isAuthor: isAuthor) { next in
                withAnimation(AppMotion.fold) { action = action == next ? nil : next }
            }
            if let notice = session.notice {
                PRNoticeText(notice: notice)
            }
        }
    }
}

/// The words for the review the bar opened, in place. Cancel closes it; sending it locks the words and closes it at
/// once, and the review goes on in the background with its toast (`PRReviewToast`).
struct PRReviewComposer: View {
    let session: PRSession
    let action: PRReviewAction
    /// Under the diff the box takes the bar's place, so it says what goes with the review; on the page the bar above
    /// it already does.
    var showsPending = true
    let close: () -> Void
    /// Sent: the box is read-only while it closes.
    @State private var isSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if showsPending {
                PRPendingComments(count: session.drafts.count)
            }
            composer
        }
    }

    private var composer: some View {
        InlineComposer(
            text: session.text(for: action.target),
            placeholder: action == .approve ? "Add a note, or just approve" : "Say something",
            buttonTitle: action.title, needsText: action != .approve && session.drafts.isEmpty,
            sendAtLeading: action == .approve
        ) { text in
            try session.submitReview(text, to: action.target(hasDrafts: !session.drafts.isEmpty))
            isSent = true
            session.discardText(for: action.target)
            close()
        } cancel: {
            session.discardText(for: action.target)
            close()
        }
        .disabled(isSent)
    }
}

/// The line comments waiting for the review, over the review's buttons and its box.
private struct PRPendingComments: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) pending comment\(count == 1 ? "" : "s") will go with your review")
                .font(.appFootnote)
                .foregroundStyle(Color.toneWaiting)
                .accessibilityIdentifier("pr-pending-comments")
        }
    }
}
