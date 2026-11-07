import PRKitCore
import PRKitDesign
import SwiftUI

/// The diff, with as little else on screen as can be: the bars leave as you read, Files and Key lines wait in a panel,
/// and a small capsule steps through the key lines. The comment box sits above the keyboard, with the line just over it.
struct PRDiffPage: View {
    @Bindable var session: PRSession
    let document: DiffDocument
    let rows: DiffRows
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { proxy in
            DiffTableView(
                document: document, rows: rows, viewed: session.viewedFiles, jump: session.jump,
                composing: session.composingLine, topInset: proxy.safeAreaInsets.top,
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
        .safeAreaBar(edge: .bottom) {
            if session.composingLine != nil {
                composer
            }
        }
        .overlay(alignment: .bottom) {
            if session.composingLine == nil, !session.isKeyboardUp {
                controls
                    .transition(.opacity)
            }
        }
        .sidePanel(isPresented: session.isShowingNavigator, close: session.closeNavigator) {
            PRNavigator(session: session, document: document, files: rows.files)
        }
        .sensoryFeedback(.selection, trigger: session.selectedKeyLine?.id)
        .task(id: session.contextLines) { await session.loadKeyLines() }
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
            setBarsHidden: { session.barsHidden = $0 },
            setKeyboardUp: { isUp in
                withAnimation(AppMotion.fold) {
                    session.isKeyboardUp = isUp
                    session.barsHidden = isUp
                }
            },
            removeDraft: { session.removeDraft($0) },
            reply: { thread, text in try await session.send(text, to: .reply(thread: thread)) },
            setResolved: { thread, resolved in try await session.setResolved(resolved, thread: thread) }
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
                alternate: .init(title: "Comment now") { words in
                    try await session.send(words, to: target)
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
            .padding(8)
            .background(Color.prCard)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let notice = session.notice {
                Text(notice)
                    .font(.appFootnote)
                    .foregroundStyle(Color("ToneBad"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.fold)
            }
            HStack(spacing: 8) {
                if !session.drafts.isEmpty {
                    finishReview
                }
                Spacer(minLength: 0)
                if !session.keyLineItems.isEmpty {
                    stepper
                }
                // Rightmost, where the panel it opens slides in from.
                panelButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var finishReview: some View {
        Button {
            withAnimation(AppMotion.swap) { session.page = .description }
        } label: {
            Text("Finish · \(session.drafts.count)")
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        .accessibilityLabel("Finish review, \(session.drafts.count) pending")
        .accessibilityIdentifier("finish-review")
        .transition(.fold)
    }

    private var panelButton: some View {
        let viewed = rows.files.filter { session.viewedFiles.contains($0.path) }.count
        return Button {
            openPanel()
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

    private func openPanel(on page: PRNavigatorPage? = nil) {
        withAnimation(AppMotion.fold) {
            if let page {
                session.navigatorPage = page
            }
            session.isShowingNavigator = true
        }
    }

    private var stepper: some View {
        let items = session.keyLineItems
        let current = items.firstIndex { $0.id == session.selectedKeyLine?.id }
        return HStack(spacing: 0) {
            stepButton("Previous key line", symbol: "chevron.left", id: "key-line-previous", step: -1)
            Button {
                openPanel(on: .keyLines)
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
