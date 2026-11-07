import PRKitCore
import PRKitDesign
import Observation
import QuartzCore
import SwiftUI

/// The diff side of a PR: either there is one, with its threads placed, or GitHub won't supply it.
enum PRDiff: Sendable {
    case document(DiffDocument, DiffRows)
    case tooLarge
}

/// What the screen shows, whole: a description and a diff that belong together.
struct PRContent: Sendable {
    let detail: PullRequestDetail
    let diff: PRDiff

    init(
        detail: PullRequestDetail, document: DiffDocument?, drafts: [PRDraftComment] = [],
        changedLinesOnly: Bool = false, note: PRKeyLines.Item? = nil
    ) {
        self.detail = detail
        let threads = detail.reviewThreads.nodes
        diff = document.map {
            .document($0, DiffRows(
                document: $0, threads: threads, drafts: drafts, changedLinesOnly: changedLinesOnly, note: note
            ))
        } ?? .tooLarge
    }

    fileprivate func replacing(
        detail: PullRequestDetail? = nil, drafts: [PRDraftComment], changedLinesOnly: Bool,
        note: PRKeyLines.Item? = nil
    ) -> PRContent {
        guard case let .document(document, _) = diff else {
            return PRContent(detail: detail ?? self.detail, document: nil)
        }
        return PRContent(
            detail: detail ?? self.detail, document: document, drafts: drafts, changedLinesOnly: changedLinesOnly,
            note: note
        )
    }
}

/// Asks the diff to show a place: a file, or a line in it. Each ask is new, so a second tap still moves it.
struct DiffJump: Equatable {
    let id = UUID()
    let path: String
    var line: Int?
    var side: PRDiffSide?
}

enum PRKeyLinesState: Sendable {
    case working
    case ready(PRKeyLines)
    case failed(String)
}

enum PRSessionState: Sendable {
    case reading
    case failed(String)
    case ready(PRContent)
}

/// One open PR, and the only place its identity and content live: `ref` can't change, the content is only ever read for
/// that ref, and everything written goes to it. The screen holds no PR state of its own, so it can't show one PR under
/// another's name. Each tap makes a new session, and a session is equal only to itself.
@MainActor
@Observable
final class PRSession: Hashable {
    private static let changedLinesKey = "prChangedLinesOnly"
    private static let contextKey = "prKeyLinesContext"

    let ref: PullRequestRef
    let timer: DiffOpenTimer
    let folds = FoldSet()
    let parseMilliseconds: Int
    let isPreloaded: Bool
    private(set) var state: PRSessionState
    /// Line comments waiting for the review they will go out with.
    private(set) var drafts: [PRDraftComment]
    /// The diff has shown once: the timer counts from there, unless the PR opened on its diff.
    var hasShownDiff = false
    /// The PR's description has shown, so a diff after it was a tap of its own.
    var hasShownDescription = false
    /// The diff is the screen on top: it, and not the PR under it, shows the Ask sheet.
    var isDiffOnScreen = false
    /// The Review shortcut: the diff arrives with its panel open on the key lines.
    var opensPanelOnArrival = false
    /// Set here first, so a file folds under Jai's thumb. GitHub follows, and a refusal puts it back.
    var viewedFiles: Set<String> = []
    private(set) var changedLinesOnly = UserDefaults.standard.bool(forKey: PRSession.changedLinesKey)
    private(set) var jump: DiffJump?
    var isShowingNavigator = false
    /// Key lines first; the panel shows Files alone where the Worker has none.
    var navigatorPage = PRNavigatorPage.keyLines
    /// Beside the diff where there is room, else over it (`PRPanelPlacement`). Set by the diff as its width changes.
    var panelPlacement = PRPanelPlacement.overlay
    /// The panel's column, put away by its button.
    var isPanelColumnHidden = false
    /// The file at the top of the diff's screen, as the reader scrolls: where Next file and Viewed start.
    var topFile: Int?
    /// The key line being looked at: marked in the list and the diff, with its note under its line, until it's closed.
    private(set) var selectedKeyLine: PRKeyLines.Item?
    /// The line of the document being commented on. The comment box sits above the keyboard, not in the diff.
    var composingLine: Int?
    /// The nav bar and tab bar have got out of the way of the code.
    var barsHidden = false
    /// Asking the PR's AI agent (`PRSession+Ask.swift`).
    var isShowingAsk = false
    var askDraft = ""
    /// A question on its way, shown as sent until the chat has it.
    var askPending: String?
    var askAnchor: PRAskQuestion.Anchor?
    var askChat: PRAskChat?
    var isSendingAsk = false
    var askError: String?
    var isKeyboardUp = false
    /// What GitHub refused when nothing on screen was waiting to say so.
    var notice: String?
    private(set) var isUpdatingBranch = false
    private(set) var isMerged = false
    private(set) var isRewriting = false
    private(set) var keyLines = PRKeyLinesState.working {
        didSet {
            // Another context's list may not hold the key line being looked at.
            if case let .ready(lines) = keyLines, let selected = selectedKeyLine,
               !lines.items.contains(where: { $0.id == selected.id }) {
                closeKeyLine()
            }
        }
    }
    /// Lines of code the model sees either side of a change: 0 the diff alone, -1 the whole file.
    private(set) var contextLines = UserDefaults.standard.object(forKey: PRSession.contextKey) as? Int
        ?? PRKeyLines.defaultContext
    private var keyLinesByContext: [Int: PRKeyLines] = [:]
    /// Half-written comments, by `PRComposerTarget.key`. A key with no text is a box open and empty.
    private var writing: [String: String] = [:]
    private let rowTitle: String?
    let model: PRsModel
    private let draftStore = PRDraftStore()

    init(
        ref: PullRequestRef, title: String?, content: PRContent?, keyLines: PRKeyLines? = nil,
        tappedAt: CFTimeInterval, model: PRsModel
    ) {
        self.ref = ref
        self.model = model
        rowTitle = title
        isPreloaded = content != nil
        let drafts = draftStore.load(ref)
        self.drafts = drafts
        let changedLinesOnly = UserDefaults.standard.bool(forKey: Self.changedLinesKey)
        state = (content?.replacing(drafts: drafts, changedLinesOnly: changedLinesOnly)).map(PRSessionState.ready)
            ?? .reading
        viewedFiles = Set(content?.detail.viewedFiles ?? [])
        timer = DiffOpenTimer(startedAt: tappedAt)
        parseMilliseconds = Int(((CACurrentMediaTime() - tappedAt) * 1000).rounded())
        if let keyLines {
            keyLinesByContext[keyLines.context] = keyLines
        }
    }

    nonisolated static func == (lhs: PRSession, rhs: PRSession) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    var label: String {
        "\(ref.repo)#\(ref.number)"
    }

    var title: String {
        if case let .ready(content) = state, let title = content.detail.title {
            return title
        }
        return rowTitle ?? label
    }

    var content: PRContent? {
        if case let .ready(content) = state {
            return content
        }
        return nil
    }

    /// Reads a PR the phone doesn't hold. A preloaded one has nothing to do here.
    func loadIfNeeded() async {
        guard case .reading = state else {
            return
        }
        do {
            let content = try await model.fetchLive(ref)
                .replacing(drafts: drafts, changedLinesOnly: changedLinesOnly, note: selectedKeyLine)
            viewedFiles = Set(content.detail.viewedFiles ?? [])
            withAnimation(AppMotion.swap) { state = .ready(content) }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return // The screen left mid-read. It reads again when it comes back.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        state = .reading
        await loadIfNeeded()
    }

    func text(for target: PRComposerTarget) -> Binding<String> {
        Binding { self.writing[target.key] ?? "" } set: { self.writing[target.key] = $0 }
    }

    /// Nil while nothing is open there.
    func openText(for target: PRComposerTarget) -> Binding<String?> {
        Binding { self.writing[target.key] } set: { self.writing[target.key] = $0 }
    }

    func editDescription() {
        withAnimation(AppMotion.fold) { writing[PRComposerTarget.description.key] = content?.detail.body ?? "" }
    }

    func updateBranch() async {
        guard let head = content?.detail.head else {
            return
        }
        isUpdatingBranch = await perform(.updateBranch(commit: head))
    }

    func merge() async {
        guard let detail = content?.detail else {
            return
        }
        isMerged = await perform(.merge(method: detail.mergeMethod?.lowercased() ?? "merge", commit: detail.head))
    }

    func setCheckbox(_ index: Int, checked: Bool) async {
        let task = content.flatMap { PRMarkdown.taskText(in: $0.detail.body, at: index) }
        await perform(.checkbox(index: index, checked: checked, task: task))
    }

    /// True when GitHub took it. Otherwise it says why, where Jai can see it. One saved for later says so too.
    @discardableResult private func perform(_ write: PRWrite) async -> Bool {
        notice = nil
        do {
            setDrafts(drafts, detail: try await model.write(write, to: ref))
            showWriteNotice()
            return true
        } catch {
            withAnimation(AppMotion.fold) { notice = error.localizedDescription }
            return false
        }
    }

    func setChangedLinesOnly(_ isOn: Bool) {
        changedLinesOnly = isOn
        UserDefaults.standard.set(isOn, forKey: Self.changedLinesKey)
        setDrafts(drafts)
    }

    func show(file path: String) {
        selectedKeyLine = nil
        rebuildRows()
        closePanelOverDiff()
        jump = DiffJump(path: path)
    }

    func closeNavigator() {
        withAnimation(AppMotion.fold) { isShowingNavigator = false }
    }

    /// A pick in the panel shows its place: the panel over the diff goes, its column stays.
    private func closePanelOverDiff() {
        if panelPlacement == .overlay {
            closeNavigator()
        }
    }

    func show(_ item: PRKeyLines.Item) {
        selectedKeyLine = item
        rebuildRows()
        closePanelOverDiff()
        jump = DiffJump(path: item.path, line: item.line, side: PRDiffSide(rawValue: item.side))
    }

    func closeKeyLine() {
        selectedKeyLine = nil
        rebuildRows()
    }

    func discardText(for target: PRComposerTarget) {
        withAnimation(AppMotion.fold) { writing[target.key] = nil }
    }

    func send(_ text: String, to target: PRComposerTarget) async throws {
        guard let content else {
            throw PRViewerError.refused("This PR has not loaded yet.")
        }
        var goingOut: [PRDraftComment] = []
        if case .review = target {
            goingOut = drafts
        }
        let write = target.write(
            body: text, head: content.detail.head, drafts: goingOut, description: content.detail.body
        )
        var detail: PullRequestDetail?
        do {
            detail = try await model.write(write, to: ref)
            showWriteNotice()
        } catch PRViewerError.saved {
            // It's in the outbox, words and drafts with it: the box is done with them.
            withAnimation(AppMotion.fold) { notice = PRViewerError.saved.localizedDescription }
        }
        let kept = drafts.filter { !goingOut.contains($0) }
        discardText(for: target)
        if let answer = target.answer {
            model.noteAnswer(answer, on: ref, head: content.detail.head)
        }
        setDrafts(kept, detail: detail)
    }

    func setResolved(_ resolved: Bool, thread: PullRequestDetail.Thread) async throws {
        do {
            setDrafts(drafts, detail: try await model.write(.resolve(thread: thread.id, resolved: resolved), to: ref))
        } catch PRViewerError.saved {
            withAnimation(AppMotion.fold) { notice = PRViewerError.saved.localizedDescription }
        }
    }

    func addDraft(_ text: String, on target: PRComposerTarget) {
        guard case let .line(path, line, side) = target else {
            return
        }
        discardText(for: target)
        setDrafts(drafts + [PRDraftComment(id: UUID(), path: path, line: line, side: side, body: text)])
    }

    func removeDraft(_ draft: PRDraftComment) {
        setDrafts(drafts.filter { $0 != draft })
    }

    private func setDrafts(_ next: [PRDraftComment], detail: PullRequestDetail? = nil) {
        drafts = next
        draftStore.save(next, for: ref)
        rebuildRows(detail: detail)
    }

    private func rebuildRows(detail: PullRequestDetail? = nil) {
        if let content {
            withAnimation(AppMotion.fold) {
                state = .ready(content.replacing(
                    detail: detail, drafts: drafts, changedLinesOnly: changedLinesOnly, note: selectedKeyLine
                ))
            }
        }
    }

    func report(document: DiffDocument, milliseconds: Double) {
        let event = PROpenEvent(
            milliseconds: Int(milliseconds.rounded()), parseMilliseconds: parseMilliseconds, preloaded: isPreloaded,
            bytes: document.data.count, lines: document.lines.count
        )
        Task { await model.report(event) }
    }
}

extension PRSession {
    /// A sample PR's write says it went nowhere (`PRSampleSet`). A real one's says nothing.
    fileprivate func showWriteNotice() {
        if let words = model.writeNotice {
            withAnimation(AppMotion.fold) { notice = words }
        }
    }
}

// MARK: - Key lines and rewrites

extension PRSession {
    func setContextLines(_ context: Int) {
        contextLines = context
        UserDefaults.standard.set(context, forKey: Self.contextKey)
    }

    /// From the phone if it has them, and otherwise from the Worker, which runs the model once for each commit and
    /// context. `retry` asks it to run again after a failure.
    func loadKeyLines(retry: Bool = false) async {
        guard offersKeyLines, let head = content?.detail.head else {
            return
        }
        let context = contextLines
        if let known = keyLinesByContext[context], !retry {
            keyLines = .ready(known)
            return
        }
        keyLines = .working
        do {
            let answer: PRKeyLines = try await model.aiAnswer(
                "key-lines", ref: ref, head: head, context: context, retry: retry
            )
            keyLinesByContext[context] = answer
            if context == contextLines {
                withAnimation(AppMotion.fold) { keyLines = .ready(answer) }
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            if context == contextLines {
                keyLines = .failed(error.localizedDescription)
            }
        }
    }

    /// Opens the description's box with the model's words in it. Nothing reaches GitHub until Jai taps Save.
    func rewriteDescription() async {
        guard let head = content?.detail.head else {
            return
        }
        isRewriting = true
        notice = nil
        defer { isRewriting = false }
        do {
            let rewrite: PRRewrite = try await model.aiAnswer("rewrite", ref: ref, head: head, retry: true)
            withAnimation(AppMotion.fold) {
                writing[PRComposerTarget.description.key] = rewrite.body
                notice = rewrite.hadTicket ? nil : "Written without a ticket: none was found for this PR."
            }
        } catch {
            withAnimation(AppMotion.fold) { notice = error.localizedDescription }
        }
    }
}
