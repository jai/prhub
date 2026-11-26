import PRKitCore
import PRKitDesign
import SwiftUI

/// What a pending comment's card can ask for. The diff's table holds these, not the session, as it holds `DiffActions`.
struct PRPendingActions {
    /// The comment's words while its box is open; nil while it is not. The session's, so a reload keeps them.
    let editText: (PRPendingComment) -> Binding<String?>
    let edit: (PRPendingComment, String) -> Void
    let remove: (PRPendingComment) -> Void
    let retry: (PRPendingComment) -> Void
    let addToFile: (PRPendingComment) -> Void

    @MainActor
    init(_ session: PRSession) {
        editText = { session.editText(for: $0) }
        edit = { session.editPending($0, body: $1) }
        remove = { session.removePending($0) }
        retry = { session.retryPending($0) }
        addToFile = { session.addPendingToFile($0) }
    }

    private init() {
        editText = { _ in .constant(nil) }
        edit = { _, _ in }
        remove = { _ in }
        retry = { _ in }
        addToFile = { _ in }
    }

    /// For a diff with no PR behind it: the font setting's sample.
    static var none: PRPendingActions {
        PRPendingActions()
    }
}

/// The words about pending comments that more than one screen says.
enum PRPendingWords {
    /// The line composer's main button. With the review on GitHub there is always exactly one review to add to, so it
    /// reads the same whatever is in it; on a Worker without pending reviews the first comment starts the review.
    static func addTitle(usesPendingReview: Bool, hasPending: Bool) -> String {
        usesPendingReview || hasPending ? "Add to review" : "Start review"
    }

    static func going(_ count: Int) -> String {
        "\(count) pending comment\(count == 1 ? "" : "s") will go with your review"
    }

    /// What a review sent now leaves behind, in plain words; nil when GitHub refused nothing.
    static func refused(comments: Int, changes: Int) -> String? {
        var words: [String] = []
        if comments == 1 {
            words.append("1 pending comment did not reach GitHub and will not go with your review. Try it again or delete it.")
        } else if comments > 1 {
            words.append(
                "\(comments) pending comments did not reach GitHub and will not go with your review. "
                    + "Try them again or delete them."
            )
        }
        if changes == 1 {
            words.append("1 change to a pending comment did not reach GitHub. The review goes with the comment as GitHub has it.")
        } else if changes > 1 {
            words.append(
                "\(changes) changes to pending comments did not reach GitHub. "
                    + "The review goes with the comments as GitHub has them."
            )
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

/// A comment of the review not submitted yet: the person's words, marked Pending, with Edit and Delete. Edit opens the
/// words in the card's own box, as the description's does. One GitHub refused says why in GitHub's words and offers
/// Try again; a line comment refused on its line can go on its file instead.
struct PRPendingCard: View {
    let comment: PRPendingComment
    let actions: PRPendingActions
    /// On the PR's page no line of code is over it, so it says where it belongs.
    var showsLocation = false

    var body: some View {
        let text = actions.editText(comment)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                StatusChip(text: "Pending", tint: Color.toneWaiting)
                if comment.isOutdated {
                    StatusChip(text: "Outdated", tint: Color.toneWaiting)
                }
                if showsLocation {
                    Text(comment.location)
                        .font(.appCaption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if text.wrappedValue == nil {
                    Button("Edit") {
                        withAnimation(AppMotion.fold) { text.wrappedValue = comment.body }
                    }
                    .accessibilityIdentifier("pending-edit")
                    Button("Delete", role: .destructive) { actions.remove(comment) }
                        .accessibilityIdentifier("pending-delete")
                }
            }
            .buttonStyle(PRButtonStyle(.plain))
            if text.wrappedValue != nil {
                InlineComposer(text: text.whileOpen, placeholder: "Comment", buttonTitle: "Save", lines: 1 ... 6) { words in
                    actions.edit(comment, words)
                } cancel: {
                    withAnimation(AppMotion.fold) { text.wrappedValue = nil }
                }
                .transition(.fold)
            } else {
                PRCommentText(comment.body)
                if let failure = comment.failure {
                    refusal(failure)
                }
            }
        }
        .padding(PRStyle.inset)
        .prCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-comment")
    }

    /// GitHub's reason, and the ways on from it.
    @ViewBuilder
    private func refusal(_ reason: String) -> some View {
        Text(reason)
            .font(.appFootnote)
            .foregroundStyle(Color.toneBad)
            .accessibilityIdentifier("pending-failure")
        HStack(spacing: Space.sm) {
            Button("Try again") { actions.retry(comment) }
                .accessibilityIdentifier("pending-retry")
            if canGoOnFile {
                Button("Add to the file instead") { actions.addToFile(comment) }
                    .accessibilityIdentifier("pending-add-to-file")
            }
        }
        .buttonStyle(PRButtonStyle(.secondary))
    }

    /// A comment of this device's that GitHub refused on its line: GitHub takes one only on a line the diff shows.
    private var canGoOnFile: Bool {
        guard case let .device(draft) = comment.origin else {
            return false
        }
        return draft.isFile != true
    }
}

/// On the PR's page, under the review's buttons: the pending comments with no line in the diff to sit under
/// (`PRSession.pendingOffDiff`), each with where it belongs.
struct PRPendingList: View {
    let session: PRSession

    var body: some View {
        let comments = session.pendingOffDiff
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Pending comments · \(comments.count)")
                    .font(.appSubheadline.weight(.semibold))
                ForEach(comments) { comment in
                    PRPendingCard(comment: comment, actions: PRPendingActions(session), showsLocation: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pr-pending-list")
        }
    }
}
