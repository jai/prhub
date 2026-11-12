import PRKitCore
import PRKitDesign
import SwiftUI

/// The diff, with as little else on screen as can be: the bars leave as you read, Files and Key lines wait in a panel,
/// and a small capsule steps through the key lines. The panel is over the code on a phone, and a column beside it where
/// the screen has room. The comment box sits above the keyboard, with the line just over it. The review bar (Approve,
/// Request changes, Comment) sits under the code and leaves with the bars; what it opens takes its place.
struct PRDiffPage: View {
    @Bindable var session: PRSession
    let document: DiffDocument
    let rows: DiffRows
    /// What the review bar opened, while its box is open.
    @State private var reviewAction: PRReviewAction?
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage(diffFontIn: nil) private var diffFont
    #if os(macOS)
    /// Read so the diff redraws when View → Make Text Bigger changes it.
    @AppStorage(MacTextSize.key) private var macTextScale = MacTextSize.standard
    #endif

    var body: some View {
        HStack(spacing: 0) {
            diff
            if session.panelPlacement == .column, session.isPanelOpen {
                Divider()
                    .ignoresSafeArea()
                PRNavigator(session: session, document: document, files: rows.files)
                    .frame(width: PanelStyle.columnWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: PRPanelPlacement.self) { [isRegularWidth] proxy in
            .fitting(width: proxy.size.width, isRegularWidth: isRegularWidth)
        } action: { placement in
            session.placePanel(placement)
        }
        .sidePanel(
            isPresented: session.panelPlacement == .overlay && session.isShowingNavigator,
            close: session.closeNavigator
        ) {
            PRNavigator(session: session, document: document, files: rows.files)
        }
        .sensoryFeedback(.selection, trigger: session.selectedKeyLine?.id)
        // Again once key lines turn on, as when the person adds their Anthropic key with the diff open.
        .task(id: KeyLinesAsk(context: session.contextLines, isOffered: session.offersKeyLines)) {
            await session.loadKeyLines()
        }
        // Each time the diff shows, and at each new head: the ticks made on his other devices.
        .task(id: session.content?.detail.head) { await session.loadReviewedKeyLines() }
    }

    private var isRegularWidth: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    private var diff: some View {
        GeometryReader { proxy in
            DiffTableView(
                document: document, rows: rows, viewed: session.viewedFiles, jump: session.jump,
                composing: session.composingLine, topInset: proxy.safeAreaInsets.top, font: diffFont,
                onContent: { session.timer.contentLaidOut() }, actions: actions
            )
            #if os(iOS)
            // Code never runs under the clock: the bars' own background goes with them.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.background)
                    .frame(height: proxy.safeAreaInsets.top)
                    .allowsHitTesting(false)
            }
            #endif
            .diffExtendsUnderBars()
        }
        .overlay(alignment: .bottom) {
            if session.composingLine == nil, reviewAction == nil, !session.isKeyboardUp {
                controls
                    .transition(.opacity)
            }
        }
        .safeAreaBar(edge: .bottom) {
            Group {
                if session.composingLine != nil {
                    composer
                } else if let reviewAction {
                    PRReviewComposer(session: session, action: reviewAction) { closeReview() }
                        .bottomStrip()
                } else if !session.barsHidden, let detail = session.content?.detail {
                    PRReviewActions(session: session, isAuthor: detail.isAuthor, action: $reviewAction)
                        .bottomStrip()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(AppMotion.fold, value: session.barsHidden)
        }
    }

    private func closeReview() {
        PRPlatform.endEditing()
        withAnimation(AppMotion.fold) { reviewAction = nil }
    }

    private var actions: DiffActions {
        DiffActions(
            folds: session.folds,
            setViewed: { session.setViewed($0, path: $1) },
            openURL: openURL,
            text: { line in PRComposerTarget(document, line: line).map(session.text(for:)) ?? .constant("") },
            replyText: { session.openText(for: .reply(thread: $0)) },
            compose: { line in withAnimation(AppMotion.fold) { session.composingLine = line } },
            closeNote: { session.closeKeyLine() },
            isReviewed: { session.isReviewed($0) },
            setReviewed: { session.setReviewed($1, $0) },
            explain: session.offersAsk ? { session.explain($0, in: document) } : nil,
            setBarsHidden: { isHidden in
                guard session.barsHidden != isHidden else {
                    return
                }
                withAnimation(AppMotion.fold) { session.barsHidden = isHidden }
            },
            setKeyboardUp: { isUp in
                withAnimation(AppMotion.fold) {
                    session.isKeyboardUp = isUp
                    session.barsHidden = isUp
                }
            },
            removeDraft: { session.removeDraft($0) },
            reply: { thread, text in try await session.send(text, to: .reply(thread: thread)) },
            setResolved: { thread, resolved in try await session.setResolved(resolved, thread: thread) },
            showsFileOnTop: { file in
                if session.topFile != file {
                    session.topFile = file
                }
            }
        )
    }

    private func closeComposer() {
        withAnimation(AppMotion.fold) { session.composingLine = nil }
    }

    @ViewBuilder private var composer: some View {
        if let index = session.composingLine, document.lines.indices.contains(index),
           let target = PRComposerTarget(document, line: document.lines[index]) {
            let line = document.lines[index]
            let text = session.text(for: target)
            let ask: ((String) -> Void)? = session.offersAsk ? { words in
                let anchor = session.askAnchor(for: target, code: document.text(of: line))
                text.wrappedValue = ""
                PRPlatform.endEditing()
                closeComposer()
                session.openAsk(about: anchor, words: words)
            } : nil
            InlineComposer(
                text: text,
                placeholder: "Comment on this line",
                buttonTitle: session.drafts.isEmpty ? "Start review" : "Add to review",
                context: document.isClipped(line) ? document.text(of: line) : nil,
                lines: 1...6,
                // The box closes at once and the toast follows the comment to GitHub, as a review's does.
                alternate: .init(title: "Comment now") { words in
                    PRPlatform.endEditing()
                    try session.submitReview(words, to: target)
                    closeComposer()
                },
                ask: ask,
                send: { words in
                    PRPlatform.endEditing()
                    session.addDraft(words, on: target)
                    closeComposer()
                },
                cancel: {
                    text.wrappedValue = ""
                    PRPlatform.endEditing()
                    closeComposer()
                }
            )
            .bottomStrip()
        }
    }

    /// The key line stepper and the panel button, floating over the code above the review bar.
    private var controls: some View {
        HStack(spacing: Space.sm) {
            Spacer(minLength: 0)
            if !session.keyLineItems.isEmpty {
                stepper
            }
            // Rightmost, where the panel it opens slides in from.
            panelButton
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.sm)
    }

    private var panelButton: some View {
        let viewed = rows.files.filter { session.viewedFiles.contains($0.path) }.count
        return Button {
            session.togglePanel()
        } label: {
            Image(systemName: "sidebar.right")
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("\(viewed) of \(rows.files.count) viewed")
        .accessibilityIdentifier("diff-files")
    }

    private var stepper: some View {
        let items = session.keyLineItems
        let current = items.firstIndex { $0.id == session.selectedKeyLine?.id }
        return HStack(spacing: 0) {
            stepButton("Previous key line", symbol: "chevron.left", id: "key-line-previous", step: -1)
            Button {
                session.openPanel(on: .keyLines)
            } label: {
                Text(current.map { "\($0 + 1) of \(items.count)" } ?? "\(items.count) key lines")
                    .font(.appFootnote.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("key-line-position")
            stepButton("Next key line", symbol: "chevron.right", id: "key-line-next", step: 1)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func stepButton(_ label: String, symbol: String, id: String, step: Int) -> some View {
        Button {
            session.stepKeyLine(by: step)
        } label: {
            Image(systemName: symbol)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

private struct KeyLinesAsk: Hashable {
    let context: Int
    let isOffered: Bool
}

private extension View {
    /// What sits under the code: the review bar, the review box or a line's comment box, on the block's ground.
    func bottomStrip() -> some View {
        padding(Space.sm)
            .background(Color.groundCard)
            .overlay(alignment: .top) { Divider() }
    }
}
