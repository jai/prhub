import PRKitCore
import PRKitDesign
import SwiftUI

/// Title and labels at the top, then the way into the diff and the review buttons, above the fold on a phone; under them
/// the PR at a glance, its status, the description and every comment, newest first unless the conversation's toggle says
/// oldest.
struct PRDescriptionView: View {
    let session: PRSession
    let detail: PullRequestDetail
    /// Pushes the diff over this PR; Review changes opens its panel on the key lines too.
    let showDiff: () -> Void
    let reviewChanges: () -> Void
    @State private var action: PRReviewAction?
    /// The open box's height, as last laid out: a change of it is the box growing or shrinking as its words do.
    @State private var boxHeight: CGFloat = 0
    /// Edit and Rewrite each ask first: a stray tap on either replaced the page with a box (Jai's feedback, build 300).
    @State private var isConfirmingEdit = false
    @State private var isConfirmingRewrite = false
    /// A label's colour moves toward readable on this page's ground.
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("prConversationNewestFirst") private var newestFirst = true
    private static let descriptionEditor = "description-editor"

    private var folds: FoldSet {
        session.folds
    }

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
                // A box grows downwards with each line typed, under the keyboard, Post and all (the bug bash's
                // keyboard bug, 2026-11-10; 13 pt under on an iPhone in the test's picture). It is brought back whole.
                .onChange(of: boxHeight) {
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
                // Before anything that can be long: the summary and the status pushed them off a phone's first screen
                // (Jai's feedback, 2026-11-23).
                PRChangesCard(detail: detail, showDiff: showDiff, reviewChanges: reviewChanges)
                PRReviewActions(session: session, isAuthor: detail.isAuthor, showsNotice: false, action: $action)
                composer
                if let summary = session.summary {
                    // A bug's tap is its line in the diff, as in Key lines.
                    PRKeyLinesSummaryCard(summary: summary, onPage: true) { bug in
                        session.show(bug)
                        showDiff()
                    }
                }
                PRStatusCard(session: session, detail: detail, folds: folds)
                // By Merge and the description, whose writes it answers for: a review's own answer is its toast.
                if let notice = session.notice {
                    PRNoticeText(notice: notice)
                }
                description
                let entries = detail.conversation(newestFirst: newestFirst)
                if !entries.isEmpty {
                    conversationHeading(count: entries.count)
                }
                ForEach(entries) { entry($0) }
            }
            .padding()
        }
        .background(Color.groundPage)
    }

    /// "Conversation" and its count, with the order it is in: a tap flips it, and the phone keeps the choice.
    private func conversationHeading(count: Int) -> some View {
        HStack(spacing: Space.sm) {
            Text("Conversation · \(count)")
                .font(.appSubheadline.weight(.semibold))
            Spacer(minLength: Space.sm)
            Button {
                withAnimation(AppMotion.fold) { newestFirst.toggle() }
            } label: {
                IconText(newestFirst ? "Newest first" : "Oldest first", icon: .commentOrder)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: PRStyle.rowHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pr-conversation-order")
        }
        .padding(.top, Space.sm)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                Text(detail.title(session.title))
                    .font(.appTitle3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrStateIcon(state: detail.listState)
            }
            Text(session.label)
                .font(.appCaption)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.xs) {
                PRAvatar(author: detail.bylineAvatar)
                Text("\(detail.byline) wants \(detail.headBranch) in \(detail.base)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pr-author")
            tickets
            labels
        }
    }

    /// The tickets the title and branch name, each opening Linear; the title above leaves their brackets out.
    @ViewBuilder private var tickets: some View {
        if let tickets = detail.tickets, !tickets.isEmpty {
            ObjectReferenceLines(references: tickets.map(ObjectReference.init), awaitsLinear: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pr-tickets")
        }
    }

    /// GitHub's labels, after a red AI trash chip when the summary found the description reads as AI slop.
    @ViewBuilder private var labels: some View {
        let isSlop = session.summary?.isSlop == true
        if isSlop || !detail.labels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    if isSlop {
                        StatusChip(text: "AI trash", tint: Color.toneBad)
                            .accessibilityIdentifier("pr-ai-slop")
                    }
                    ForEach(detail.labels) { label in
                        StatusChip(
                            text: label.name,
                            tint: GitHubLabelColor(hex: label.color).readable(dark: colorScheme == .dark).color
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        if let action {
            PRReviewComposer(session: session, action: action, showsPending: false) {
                withAnimation(AppMotion.fold) { self.action = nil }
            }
            .padding(PRStyle.inset)
            .prCard()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boxHeight = $0 }
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boxHeight = $0 }
                .id(Self.descriptionEditor)
                .transition(.fold)
            } else {
                let text = detail.body.isEmpty ? "No description." : PRMarkdown.clean(detail.body)
                let opening = PRMarkdown.leadingHeading(text)
                VStack(alignment: .leading, spacing: Space.sm) {
                    descriptionActions(heading: opening?.heading)
                    if opening == nil {
                        Divider()
                    }
                    let body = opening?.rest ?? text
                    if !body.isEmpty {
                        PRCommentText(body) { index, checked in
                            Task { await session.setCheckbox(index, checked: checked) }
                        }
                    }
                }
            }
        }
        .padding(PRStyle.inset)
        .prCard()
    }

    /// Explain, Rewrite and Edit, in a row above the words, apart from them and from each other, so a tap meant for the
    /// text never lands on one. A description that opens on a heading has it at the row's start, where the row's empty
    /// room was (Jai's feedback, build 305). Rewrite and Edit ask first.
    private func descriptionActions(heading: String?) -> some View {
        HStack(spacing: Space.lg) {
            if let heading {
                Text((try? AttributedString(markdown: heading)) ?? AttributedString(heading))
                    .font(.appFootnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("pr-description-heading")
            } else {
                Spacer(minLength: 0)
            }
            if session.offersAsk {
                Button("Explain this PR", systemImage: AppIcon.explainPR.symbol) { session.explainPR() }
                    .accessibilityIdentifier("pr-explain")
            }
            if session.isRewriting {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: PRStyle.controlHeight, minHeight: PRStyle.controlHeight)
            } else if session.offersRewrite {
                Button("Rewrite description", systemImage: AppIcon.rewriteDescription.symbol) {
                    isConfirmingRewrite = true
                }
                .accessibilityIdentifier("pr-rewrite-description")
                .confirmationDialog(
                    "Rewrite the description with AI?", isPresented: $isConfirmingRewrite, titleVisibility: .visible
                ) {
                    Button("Rewrite description") { Task { await session.rewriteDescription() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The AI writes a new Description section into a box. GitHub has it only when you tap Save.")
                }
            }
            Button("Edit description", systemImage: AppIcon.editDescription.symbol) { isConfirmingEdit = true }
                .accessibilityIdentifier("pr-edit-description")
                .confirmationDialog("Edit the description?", isPresented: $isConfirmingEdit, titleVisibility: .visible) {
                    Button("Edit description") { session.editDescription() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It opens in a box. GitHub has your change only when you tap Save.")
                }
        }
        .buttonStyle(PRButtonStyle(.secondary, iconOnly: true))
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
