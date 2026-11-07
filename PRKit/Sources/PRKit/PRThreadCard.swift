import PRKitCore
import PRKitDesign
import SwiftUI

/// A review thread: resolved ones start closed, open ones start open, and either folds with a tap on its header. A reply
/// opens in the box itself.
struct PRThreadCard: View {
    let thread: PullRequestDetail.Thread
    let isCollapsed: Bool
    /// Nil while no reply is open.
    @Binding var replyText: String?
    let onToggle: () -> Void
    let reply: (String) async throws -> Void
    let setResolved: (Bool) async throws -> Void
    @State private var isResolving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.comments.nodes) { comment in
                        Divider()
                        VStack(alignment: .leading, spacing: Space.sm) {
                            PRAuthorLine(author: comment.author, date: comment.createdAt)
                            PRCommentText(PRMarkdown.clean(comment.body))
                        }
                        .padding(PRStyle.inset)
                    }
                    Divider()
                    replyArea
                }
                .transition(.fold)
            }
        }
        .prCard()
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.sm) {
                PRChevron(isCollapsed: isCollapsed)
                Text(location)
                    .font(.appCaption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if thread.isOutdated == true {
                    StatusChip(text: "Outdated", tint: Color.toneWaiting)
                }
                if thread.isResolved {
                    StatusChip(text: "Resolved", tint: Color.inkQuiet)
                }
                Text("\(thread.comments.nodes.count)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(PRStyle.inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-header")
    }

    @ViewBuilder private var replyArea: some View {
        if replyText != nil {
            let text = $replyText.whileOpen
            InlineComposer(text: text, placeholder: "Reply", buttonTitle: "Reply") { text in
                try await reply(text)
            } cancel: {
                withAnimation(AppMotion.fold) { replyText = nil }
            }
            .padding(PRStyle.inset)
            .transition(.fold)
        } else {
            HStack(spacing: 0) {
                Button("Reply") {
                    withAnimation(AppMotion.fold) { replyText = "" }
                }
                .accessibilityIdentifier("thread-reply")
                Spacer()
                if canChangeResolution {
                    Button(thread.isResolved ? "Unresolve" : "Resolve") { Task { await changeResolution() } }
                        .disabled(isResolving)
                        .accessibilityIdentifier("thread-resolve")
                }
            }
            .buttonStyle(PRButtonStyle(.plain))
            .padding(.vertical, Space.xs)
            if let failure {
                Text(failure)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .padding([.horizontal, .bottom], PRStyle.inset)
                    .transition(.fold)
            }
        }
    }

    private var canChangeResolution: Bool {
        (thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve) ?? false
    }

    private func changeResolution() async {
        isResolving = true
        failure = nil
        defer { isResolving = false }
        do {
            try await setResolved(!thread.isResolved)
        } catch {
            withAnimation(AppMotion.fold) { failure = error.localizedDescription }
        }
    }

    private var location: String {
        thread.line.map { "\(thread.path):\($0)" } ?? thread.path
    }
}

/// Every file in the diff, and how far through them Jai is. A tap shows the file.
struct PRFileList: View {
    let files: [DiffRows.File]
    let viewed: Set<String>
    let show: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.path) { file in
                    Button { show(file.path) } label: { row(file) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("file-row-\(file.path)")
                    Divider()
                }
            }
        }
    }

    private func row(_ file: DiffRows.File) -> some View {
        let isViewed = viewed.contains(file.path)
        return HStack(spacing: Space.sm) {
            Image(systemName: isViewed ? "checkmark.circle.fill" : "circle")
                .font(.appFootnote)
                .foregroundStyle(isViewed ? Color.toneGood : Color.secondary)
            Text(file.path)
                .font(.appCaption.monospaced())
                .lineLimit(2)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("+\(file.change.added)")
                .font(.appCaption.monospacedDigit())
                .foregroundStyle(Color.toneGood)
            Text("−\(file.change.removed)")
                .font(.appCaption.monospacedDigit())
                .foregroundStyle(Color.toneBad)
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// A line comment waiting for its review: Jai's words, not yet on GitHub, and marked so.
struct PRDraftCard: View {
    let draft: PRDraftComment
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                StatusChip(text: "Pending", tint: Color.toneWaiting)
                Spacer()
                Button("Delete", role: .destructive, action: remove)
                    .buttonStyle(PRButtonStyle(.plain))
            }
            PRCommentText(draft.body)
        }
        .padding(PRStyle.inset)
        .prCard()
    }
}
