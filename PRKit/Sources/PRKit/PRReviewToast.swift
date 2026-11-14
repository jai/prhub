import PRKitCore
import PRKitDesign
import SwiftUI

/// A review on its way after its box has closed: the toast follows it from the tap to GitHub's answer (DESIGN.md,
/// "Toast"). One at a time; a new review takes its place.
struct PRReviewToast: Identifiable, Equatable {
    enum Phase: Equatable {
        case sending
        /// Saved in the host's outbox while the phone is offline: it goes when it is back.
        case waitingForNetwork
        case done
        case failed(String)
    }

    let id = UUID()
    let ref: PullRequestRef
    let write: PRWrite
    /// The line comments that went with it: back on the PR if it fails, gone again if Retry sends them.
    let drafts: [PRDraftComment]
    /// The head it answers and Jai's answer in the Worker's words (`PRComposerTarget.answer`), so the list marks the
    /// PR answered from the moment GitHub takes it.
    let head: String
    let answer: String?
    var phase = Phase.sending
    /// The outbox's id for it, once saved there: a later answer or refusal finds the toast by it.
    var job: String?
    /// The PR's screen, while it is open: told what became of the review, so it shows the drafts and words again.
    let settle: @MainActor (Phase, PullRequestDetail?) -> Void

    static func == (lhs: PRReviewToast, rhs: PRReviewToast) -> Bool {
        lhs.id == rhs.id && lhs.phase == rhs.phase
    }

    var words: String {
        switch phase {
        case .sending: isComment ? "Posting comment…" : "Submitting review…"
        case .waitingForNetwork: "Saved on this phone. It goes when you're online."
        case .done: doneWords
        case let .failed(reason): "\(isComment ? "Comment" : "Review") not sent. \(reason)"
        }
    }

    /// The bar's Comment with no line comments waiting, a line's Comment now, or a reply: a comment, not a review.
    var isComment: Bool {
        switch write {
        case .comment, .line, .reply: true
        default: false
        }
    }

    private var doneWords: String {
        guard case let .review(event, _, _, _) = write else {
            return "Comment posted"
        }
        return switch event {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Comment posted"
        }
    }

    /// The bar along its foot follows a review going or landed; waiting offline or refused, it has nothing to follow.
    var showsProgress: Bool {
        switch phase {
        case .sending, .done: true
        case .waitingForNetwork, .failed: false
        }
    }

    var icon: AppIcon? {
        switch phase {
        case .sending: nil
        case .waitingForNetwork: .offline
        case .done: .done
        case .failed: .problem
        }
    }

    var tone: Color {
        switch phase {
        case .sending: .secondary
        case .waitingForNetwork: .toneWaiting
        case .done: .toneGood
        case .failed: .toneBad
        }
    }
}

extension PRsModel {
    /// Sends a review whose box has already closed, through the outbox where the host has one, so it survives the app
    /// going to the background. The toast says each step; a refusal stays on it with Retry.
    func submitReview(
        _ write: PRWrite, to ref: PullRequestRef, drafts: [PRDraftComment], head: String, answer: String?,
        settle: @escaping @MainActor (PRReviewToast.Phase, PullRequestDetail?) -> Void
    ) {
        let toast = PRReviewToast(
            ref: ref, write: write, drafts: drafts, head: head, answer: answer, settle: settle
        )
        withAnimation(AppMotion.fold) { reviewToast = toast }
        Task { await send(toast) }
    }

    /// Sends the toast's review again, its line comments with it.
    func retryReview() {
        guard var toast = reviewToast, case .failed = toast.phase else {
            return
        }
        toast.phase = .sending
        toast.job = nil
        removeDrafts(toast.drafts, from: toast.ref)
        withAnimation(AppMotion.swap) { reviewToast = toast }
        toast.settle(.sending, nil)
        Task { await send(toast) }
    }

    func dismissReviewToast() {
        withAnimation(AppMotion.fold) { reviewToast = nil }
    }

    private func send(_ toast: PRReviewToast) async {
        if let samples {
            try? await Task.sleep(for: samples.reviewDelay)
            if let refusal = samples.refusesFirstReview, !sampleReviewRefused {
                sampleReviewRefused = true
                fail(toast.id, PRWorkerError.refused(refusal).localizedDescription)
                return
            }
        }
        do {
            let outcome = try await write(toast.write, to: toast.ref) { job in
                update(toast.id) { $0.job = job }
            }
            switch outcome {
            case let .posted(detail): land(toast.id, detail: detail)
            case .queued(.waitingForNetwork): update(toast.id) { $0.phase = .waitingForNetwork }
            case .queued(.sending): break
            }
        } catch {
            fail(toast.id, error.localizedDescription)
        }
    }

    /// The outbox's answer after its wait: the toast's review landed.
    func reviewLanded(job: String, data: Data) -> Bool {
        guard let toast = reviewToast, toast.job == job else {
            return false
        }
        land(toast.id, detail: try? PullRequestDetail.decode(data))
        Task { await refresh(.pull) }
        return true
    }

    /// The outbox's refusal after its wait: said on the toast, with Retry, rather than on the list.
    func reviewRefused(job: String, reason: String) -> Bool {
        guard let toast = reviewToast, toast.job == job else {
            return false
        }
        fail(toast.id, reason)
        return true
    }

    private func land(_ id: UUID, detail: PullRequestDetail?) {
        guard let toast = reviewToast, toast.id == id else {
            return
        }
        if let answer = toast.answer {
            noteAnswer(answer, on: toast.ref, head: toast.head)
        }
        update(id) { $0.phase = .done }
        toast.settle(.done, detail)
        Task {
            try? await Task.sleep(for: ToastStyle.dwell)
            if reviewToast?.id == id {
                dismissReviewToast()
            }
        }
    }

    /// A refusal gives the line comments back to the PR, so dismissing the toast loses nothing but the words.
    private func fail(_ id: UUID, _ reason: String) {
        guard let toast = reviewToast, toast.id == id else {
            return
        }
        let store = PRDraftStore()
        let kept = store.load(toast.ref)
        store.save(kept + toast.drafts.filter { !kept.contains($0) }, for: toast.ref)
        update(id) { $0.phase = .failed(reason) }
        toast.settle(.failed(reason), nil)
    }

    private func removeDrafts(_ drafts: [PRDraftComment], from ref: PullRequestRef) {
        let store = PRDraftStore()
        store.save(store.load(ref).filter { !drafts.contains($0) }, for: ref)
    }

    private func update(_ id: UUID, _ change: (inout PRReviewToast) -> Void) {
        guard var toast = reviewToast, toast.id == id else {
            return
        }
        change(&toast)
        withAnimation(AppMotion.swap) { reviewToast = toast }
    }
}

/// The review's toast at the top of the screen, over whatever is open: it slides down from above the screen, changes its
/// words in place while a bar along its foot fills, and slides back up once GitHub has the review. A failure stays, with
/// the reason, Retry and a way to put it away.
struct PRReviewToastView: View {
    let model: PRsModel

    var body: some View {
        ZStack {
            if let toast = model.reviewToast {
                PRReviewToastBox(toast: toast, model: model)
                    .id(toast.id)
                    .transition(.offset(y: -ToastStyle.travel).combined(with: .opacity))
            }
        }
        .animation(AppMotion.fold, value: model.reviewToast?.id)
        .sensoryFeedback(trigger: model.reviewToast?.phase) { _, phase in
            switch phase {
            case .done: .success
            case .failed: .error
            default: nil
            }
        }
    }
}

/// One toast: its mark, words and buttons, and the bar that follows the review.
private struct PRReviewToastBox: View {
    let toast: PRReviewToast
    let model: PRsModel
    /// How far the bar has filled: towards `ToastStyle.progressWhileSending` while it goes, whole once it has landed.
    @State private var progress = 0.0

    var body: some View {
        HStack(spacing: Space.sm) {
            Group {
                if let icon = toast.icon {
                    Image(icon)
                        .foregroundStyle(toast.tone)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentTransition(.symbolEffect(.replace))
            Text(toast.words)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .accessibilityIdentifier("pr-review-toast-words")
            if case .failed = toast.phase {
                Button("Retry") { model.retryReview() }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .accessibilityIdentifier("pr-review-toast-retry")
                Button("Dismiss", systemImage: AppIcon.close.symbol) { model.dismissReviewToast() }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pr-review-toast-dismiss")
            }
        }
        .padding(.horizontal, PRStyle.inset)
        .padding(.vertical, Space.sm)
        .overlay(alignment: .bottomLeading) { bar }
        .frame(maxWidth: ToastStyle.maxWidth)
        .background(Color.groundCard)
        .clipShape(.rect(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.line, lineWidth: PRStyle.hairline)
        }
        .shadow(color: .black.opacity(ToastStyle.shadowOpacity), radius: ToastStyle.shadowRadius, y: ToastStyle.shadowY)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xs)
        .animation(AppMotion.swap, value: toast.phase)
        .onChange(of: toast.phase, initial: true) { _, phase in follow(phase) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-toast")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Along the foot: the tint while it goes, green once it lands; none while it waits or after it failed.
    private var bar: some View {
        GeometryReader { box in
            Rectangle()
                .fill(toast.phase == .done ? Color.toneGood : Color.accentColor)
                .frame(width: box.size.width * progress)
        }
        .frame(height: ToastStyle.progressHeight)
        .opacity(toast.showsProgress ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func follow(_ phase: PRReviewToast.Phase) {
        switch phase {
        case .sending:
            progress = 0
            withAnimation(ToastStyle.progressMotion) { progress = ToastStyle.progressWhileSending }
        case .done:
            withAnimation(AppMotion.swap) { progress = 1 }
        case .waitingForNetwork, .failed:
            break
        }
    }
}
