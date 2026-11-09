import PRKitCore
import PRKitDesign
import SwiftUI

/// Title, labels and status at the top, the actions under them, then the description and every comment in order.
struct PRDescriptionView: View {
    let session: PRSession
    let detail: PullRequestDetail
    /// Pushes the diff over this PR; Review changes opens its panel on the key lines too.
    let showDiff: () -> Void
    let reviewChanges: () -> Void
    @State private var action: PRReviewAction?
    private static let descriptionEditor = "description-editor"

    private var folds: FoldSet { session.folds }

    var body: some View {
        ScrollViewReader { proxy in
            page
                #if os(iOS)
                // The keyboard's arrival is what covers a box that has just opened, Post and all.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    reveal(in: proxy)
                }
                .onChange(of: action) {
                    Task { @MainActor in reveal(in: proxy) }
                }
                #endif
        }
    }

    /// The whole of the box that is open, its buttons included, above the keyboard.
    private func reveal(in proxy: ScrollViewProxy) {
        withAnimation(AppMotion.fold) {
            if let action {
                proxy.scrollTo(action, anchor: .bottom)
            } else if session.openText(for: .description).wrappedValue != nil {
                proxy.scrollTo(Self.descriptionEditor, anchor: .bottom)
            }
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.md) {
                header
                PRChangesCard(detail: detail, showDiff: showDiff, reviewChanges: reviewChanges)
                PRStatusCard(session: session, detail: detail, folds: folds)
                PRReviewActions(session: session, isAuthor: detail.isAuthor, action: $action)
                composer
                description
                let entries = detail.conversation
                if !entries.isEmpty {
                    Text("Conversation · \(entries.count)")
                        .font(.appSubheadline.weight(.semibold))
                        .padding(.top, Space.sm)
                }
                ForEach(entries) { entry($0) }
            }
            .padding()
        }
        .background(Color.groundPage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                Text(session.title)
                    .font(.appTitle3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrStateIcon(state: detail.listState)
            }
            Text(session.label)
                .font(.appCaption)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.xs) {
                PRAvatar(author: detail.author)
                Text("\(detail.author?.login ?? "ghost") wants \(detail.headBranch) in \(detail.base)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            labels
        }
    }

    @ViewBuilder private var labels: some View {
        if !detail.labels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(detail.labels) { StatusChip(text: $0.name, tint: Color(githubHex: $0.color)) }
                }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        if let action {
            PRReviewComposer(session: session, action: action) {
                withAnimation(AppMotion.fold) { self.action = nil }
            }
            .padding(PRStyle.inset)
            .prCard()
            .id(action)
            .transition(.fold)
        }
    }

    private var description: some View {
        Group {
            let text = session.openText(for: .description)
            if text.wrappedValue != nil {
                InlineComposer(
                    text: text.whileOpen, placeholder: "Describe the change", buttonTitle: "Save", needsText: false
                ) { try await session.send($0, to: .description) } cancel: {
                    session.discardText(for: .description)
                }
                .id(Self.descriptionEditor)
                .transition(.fold)
            } else {
                let text = detail.body.isEmpty ? "No description." : PRMarkdown.clean(detail.body)
                PRCommentText(text, firstBlockInset: 56) { index, checked in
                    Task { await session.setCheckbox(index, checked: checked) }
                }
                .overlay(alignment: .topTrailing) { descriptionActions }
            }
        }
        .padding(PRStyle.inset)
        .prCard()
    }

    private var descriptionActions: some View {
        HStack(spacing: Space.md) {
            if session.isRewriting {
                ProgressView()
                    .controlSize(.small)
            } else if session.offersRewrite {
                Button("Rewrite description", systemImage: "sparkles") {
                    Task { await session.rewriteDescription() }
                }
                .accessibilityIdentifier("pr-rewrite-description")
            }
            Button("Edit description", systemImage: "pencil") { session.editDescription() }
                .accessibilityIdentifier("pr-edit-description")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func entry(_ entry: PullRequestDetail.Entry) -> some View {
        switch entry {
        case let .comment(comment):
            card(id: comment.id, author: comment.author, date: comment.createdAt, state: nil, body: comment.body)
        case let .review(review):
            card(id: review.id, author: review.author, date: review.submittedAt, state: review.state, body: review.body)
        case let .thread(thread):
            PRThreadCard(
                thread: thread, isCollapsed: thread.isResolved != folds.isFlipped(thread.id),
                replyText: session.openText(for: .reply(thread: thread)),
                onToggle: { folds.toggle(thread.id) },
                reply: { try await session.send($0, to: .reply(thread: thread)) },
                setResolved: { try await session.setResolved($0, thread: thread) }
            )
        }
    }

    private func card(
        id: String, author: PullRequestDetail.Author?, date: Date?, state: String?, body: String
    ) -> some View {
        let isCollapsed = folds.isFlipped(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { folds.toggle(id) } label: {
                HStack(spacing: Space.sm) {
                    PRAuthorLine(author: author, date: date)
                    Spacer(minLength: 4)
                    if let badge = Self.badge(state) {
                        badge
                    }
                    PRChevron(isCollapsed: isCollapsed)
                }
                .padding(PRStyle.inset)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if !isCollapsed, !body.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    PRCommentText(PRMarkdown.clean(body))
                        .padding(PRStyle.inset)
                }
                .transition(.fold)
            }
        }
        .prCard()
    }

    private static func badge(_ state: String?) -> StatusChip? {
        switch state {
        case "APPROVED": StatusChip(text: "Approved", tint: Color.toneGood)
        case "CHANGES_REQUESTED": StatusChip(text: "Changes requested", tint: Color.toneBad)
        case "DISMISSED": StatusChip(text: "Dismissed", tint: Color.inkQuiet)
        case "COMMENTED": StatusChip(text: "Reviewed", tint: Color.inkQuiet)
        default: nil
        }
    }
}

private extension Color {
    /// GitHub's label colours: six hex digits, no `#`.
    init(githubHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
