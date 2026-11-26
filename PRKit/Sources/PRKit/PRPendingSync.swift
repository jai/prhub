import Foundation
import PRKitCore

/// A PR's screen, told when its pending comments changed: by an edit, an answer from GitHub or a refusal, whichever
/// screen or launch began it. `detail` is the PR as GitHub's answer has it, where there was one.
@MainActor
protocol PRPendingFollower: AnyObject {
    func pendingChanged(detail: PullRequestDetail?)
}

/// Keeps a PR's pending review the same on GitHub and on this device. GitHub's pending review is the truth; the device
/// keeps only what GitHub does not have yet (`PRPendingDevice`): comments written here, and edits and removals of
/// comments GitHub holds. Each is saved first, shown at once, then sent through the model's write path, so the host's
/// outbox carries it through a dead zone or a relaunch and posts it once. A refusal stays on its comment until it is
/// tried again or deleted. The model owns this, not a screen: an answer or a refusal that comes after the screen has
/// gone, or after a relaunch, still finds its comment by the outbox's id for it.
@MainActor
final class PRPendingSync {
    /// What a send carries: a comment of this device's, or a change to one of GitHub's.
    private enum Item {
        case draft(UUID)
        case change(comment: String)

        var key: String {
            switch self {
            case let .draft(id): id.uuidString
            case let .change(comment): "change:\(comment)"
            }
        }
    }

    /// What a late refusal came to (`refused(job:reason:)`).
    enum Refusal {
        /// The job was not a pending comment's.
        case notPending
        /// Its comment says why, from now on.
        case failed
        /// GitHub no longer has the comment the change was for: the change is dropped, and nothing failed.
        case settled
    }

    /// What GitHub's pending review holds, from the newest detail a screen was given.
    private struct Context {
        /// GitHub's id of the PR, which an add names.
        let pullRequest: String
        var comments: [PRPendingReview.Comment]
    }

    /// The Worker's words for an edit or a removal of a comment that is no longer in the pending review.
    private static let goneWords = "no longer in your unsent review"

    private weak var model: PRsModel?
    private let store: PRDraftStore
    private var contexts: [PullRequestRef: Context] = [:]
    /// Sends handed to the write path in this launch and not yet answered, by `sendKey`, counted: a comment sent, stopped
    /// and sent again is on its way twice for a moment.
    private var sending: [String: Int] = [:]
    /// Each PR's sends go one after another, in the order they were made.
    private var syncs: [PullRequestRef: Task<Void, Never>] = [:]
    private var followers: [PullRequestRef: [Follower]] = [:]

    private struct Follower {
        weak var screen: (any PRPendingFollower)?
    }

    init(model: PRsModel, store: PRDraftStore) {
        self.model = model
        self.store = store
    }

    // MARK: - What a screen reads

    func follow(_ ref: PullRequestRef, _ screen: any PRPendingFollower) {
        followers[ref] = (followers[ref] ?? []).filter { $0.screen != nil } + [Follower(screen: screen)]
    }

    /// GitHub's pending review as `detail` has it, from a Worker that reads one. What the device holds is checked
    /// against it, and what is still unsent goes.
    func note(_ detail: PullRequestDetail, for ref: PullRequestRef) {
        guard detail.pendingReview.isSupported else {
            contexts[ref] = nil
            return
        }
        contexts[ref] = Context(pullRequest: detail.id ?? "", comments: detail.pendingReview.comments)
        reconcile(ref)
        sync(ref)
    }

    /// The one list of the PR's pending comments: GitHub's with this device's changes on them, then the device's own.
    func comments(for ref: PullRequestRef) -> [PRPendingComment] {
        store.loadPending(ref).comments(over: contexts[ref]?.comments ?? [])
    }
}

// MARK: - What a screen does

extension PRPendingSync {
    func add(_ drafts: [PRDraftComment], to ref: PullRequestRef) {
        var device = store.loadPending(ref)
        device.drafts += drafts
        save(device, for: ref)
        changed(ref)
        sync(ref)
    }

    /// New words, shown at once. GitHub's comment gets an edit. The device's own changes here: if its add can still be
    /// stopped it goes again with the new words, and if not the edit follows it once it has landed.
    func edit(_ comment: PRPendingComment, body: String, on ref: PullRequestRef) async {
        var device = store.loadPending(ref)
        switch comment.origin {
        case let .github(id):
            let earlier = device.changes.first { $0.comment == id }
            device.changes.removeAll { $0.comment == id }
            device.changes.append(PRPendingChange(comment: id, body: body))
            save(device, for: ref)
            changed(ref)
            // Best effort: the PR's writes go in order, so the newest words are the ones that stay.
            if let job = earlier?.job {
                _ = await stop(job)
            }
        case let .device(draft):
            guard let index = device.drafts.firstIndex(where: { $0.id == draft.id }) else {
                return
            }
            device.drafts[index].body = body
            if device.drafts[index].sync?.failure != nil {
                device.drafts[index].sync = nil
            }
            let job = device.drafts[index].sync?.job
            save(device, for: ref)
            changed(ref)
            if let job, await stop(job) {
                change(draft.id, on: ref) { $0.sync = nil }
            }
        }
        sync(ref)
    }

    /// Gone at once. GitHub's comment gets a removal. The device's own is dropped: if its add can't be stopped any
    /// more, the removal follows it once it has landed.
    func delete(_ comment: PRPendingComment, on ref: PullRequestRef) async {
        var device = store.loadPending(ref)
        switch comment.origin {
        case let .github(id):
            let earlier = device.changes.first { $0.comment == id }
            device.changes.removeAll { $0.comment == id }
            device.changes.append(PRPendingChange(comment: id, body: nil))
            save(device, for: ref)
            changed(ref)
            if let job = earlier?.job {
                _ = await stop(job)
            }
        case let .device(draft):
            guard let index = device.drafts.firstIndex(where: { $0.id == draft.id }) else {
                return
            }
            guard device.drafts[index].sync?.sent != nil else {
                device.drafts.remove(at: index)
                save(device, for: ref)
                changed(ref)
                return
            }
            let job = device.drafts[index].sync?.job
            device.drafts[index].sync?.isDeleted = true
            save(device, for: ref)
            changed(ref)
            if let job, await stop(job) {
                var stopped = store.loadPending(ref)
                stopped.drafts.removeAll { $0.id == draft.id }
                save(stopped, for: ref)
            }
        }
        sync(ref)
    }

    /// A refused comment or change, sent again as it is.
    func retry(_ comment: PRPendingComment, on ref: PullRequestRef) {
        var device = store.loadPending(ref)
        switch comment.origin {
        case let .github(id):
            guard let index = device.changes.firstIndex(where: { $0.comment == id }) else {
                return
            }
            device.changes[index].failure = nil
        case let .device(draft):
            guard let index = device.drafts.firstIndex(where: { $0.id == draft.id }) else {
                return
            }
            device.drafts[index].sync = nil
        }
        save(device, for: ref)
        changed(ref)
        sync(ref)
    }

    /// A comment GitHub refused on its line, sent again as a comment on the whole file: its words say which line it
    /// was written on. GitHub takes a line comment only on a line the diff shows.
    func addToFile(_ comment: PRPendingComment, on ref: PullRequestRef) {
        guard case let .device(draft) = comment.origin, draft.isFile != true else {
            return
        }
        change(draft.id, on: ref) { draft in
            draft.body = "Line \(draft.line): \(draft.body)"
            draft.isFile = true
            draft.sync = nil
        }
        changed(ref)
        sync(ref)
    }

    // MARK: - Sending

    /// Sends everything not sent yet, in order, after whatever this PR is already sending. It ends once each is saved
    /// in the host's outbox, or, with no outbox, answered: a review submitted after it goes behind them.
    @discardableResult
    func sync(_ ref: PullRequestRef) -> Task<Void, Never> {
        let earlier = syncs[ref]
        let task = Task { [weak self] in
            await earlier?.value
            await self?.sendUnsent(ref)
        }
        syncs[ref] = task
        return task
    }

    /// The network is back: every PR this launch has seen sends what waited. With an outbox the outbox does this
    /// itself; this is for a host without one.
    func syncAll() {
        for ref in contexts.keys {
            sync(ref)
        }
    }

    private func sendUnsent(_ ref: PullRequestRef) async {
        guard let context = contexts[ref] else {
            return
        }
        // Each goes once a run: one that didn't get through waits for the next run, not for this loop.
        var tried: Set<String> = []
        while true {
            var device = store.loadPending(ref)
            if let index = device.drafts.firstIndex(where: { $0.isUnsent && !tried.contains($0.id.uuidString) }) {
                let draft = device.drafts[index]
                tried.insert(draft.id.uuidString)
                device.drafts[index].sync = PRDraftSync(sent: draft.body)
                save(device, for: ref)
                let write = PRWrite.pendingAdd(
                    pullRequest: context.pullRequest, path: draft.path, line: draft.isFile == true ? nil : draft.line,
                    side: draft.side, body: draft.body
                )
                await launch(write, to: ref, for: .draft(draft.id))
            } else if let index = device.changes.firstIndex(where: { $0.isUnsent && !tried.contains($0.sendKey) }) {
                let change = device.changes[index]
                tried.insert(change.sendKey)
                device.changes[index].isSent = true
                save(device, for: ref)
                let write = change.body.map { PRWrite.pendingEdit(comment: change.comment, body: $0) }
                    ?? .pendingDelete(comment: change.comment)
                await launch(write, to: ref, for: .change(comment: change.comment))
            } else {
                return
            }
        }
    }

    /// Hands `write` to the model's write path and comes back once it is saved in the outbox, so the next send goes
    /// behind it; with no outbox, once it is answered. The answer is taken whenever it comes.
    private func launch(_ write: PRWrite, to ref: PullRequestRef, for item: Item) async {
        guard let model else {
            return
        }
        hold(item.key)
        await withCheckedContinuation { (saved: CheckedContinuation<Void, Never>) in
            Task {
                var job: String?
                let result: Result<PRWriteOutcome, any Error>
                do {
                    result = try .success(await model.write(write, to: ref) { id in
                        job = id
                        self.saved(as: id, item, on: ref)
                        saved.resume()
                    })
                } catch {
                    result = .failure(error)
                }
                self.finished(item, job: job, result, on: ref)
                if job == nil {
                    saved.resume()
                }
            }
        }
    }

    /// The outbox has it under `job`: kept on the device with the comment, so its answer finds it after a relaunch.
    private func saved(as job: String, _ item: Item, on ref: PullRequestRef) {
        hold(job)
        store.setOwner(ref, ofJob: job)
        var device = store.loadPending(ref)
        switch item {
        case let .draft(id):
            if let index = device.drafts.firstIndex(where: { $0.id == id }) {
                device.drafts[index].sync?.job = job
            }
        case let .change(comment):
            if let index = device.changes.firstIndex(where: { $0.comment == comment && $0.isSent == true }) {
                device.changes[index].job = job
            }
        }
        store.save(device, for: ref)
    }

    /// The write path came back: with GitHub's answer, with the send still going in the outbox, or with a failure.
    private func finished(
        _ item: Item, job: String?, _ result: Result<PRWriteOutcome, any Error>, on ref: PullRequestRef
    ) {
        release(item.key)
        if let job {
            release(job)
        }
        switch result {
        case let .success(.posted(detail)):
            landed(item, job: job, on: ref, detail: detail)
        case .success(.queued):
            break
        case let .failure(error):
            if Self.isRefusal(error) {
                _ = refuse(item, job: job, on: ref, reason: error.localizedDescription)
            } else {
                // Not sent, and nobody refused it: it waits, and goes when the network is back or the PR is read again.
                wait(item, job: job, on: ref)
            }
        }
    }

    /// GitHub's or the phone's no, which sending again as it is won't change; anything else is a send that didn't
    /// get through.
    private static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case is URLError, is CancellationError: false
        case let error as PRWorkerError:
            if case .refused = error {
                true
            } else {
                error.isPermanent
            }
        default: true
        }
    }
}

// MARK: - Answers

extension PRPendingSync {
    /// The outbox's answer to a job after its wait, or after a relaunch. False for a job that is not a pending
    /// comment's.
    func answered(job: String, data: Data) -> Bool {
        guard let ref = store.owner(ofJob: job), let item = item(of: job, on: ref) else {
            return false
        }
        landed(item, job: job, on: ref, detail: try? PullRequestDetail.decode(data))
        return true
    }

    /// The outbox's refusal of a job after its wait, or after a relaunch: its comment is marked failed on the device,
    /// where it stays until it is tried again or deleted.
    func refused(job: String, reason: String) -> Refusal {
        guard let ref = store.owner(ofJob: job), let item = item(of: job, on: ref) else {
            return .notPending
        }
        return refuse(item, job: job, on: ref, reason: reason)
    }

    private func item(of job: String, on ref: PullRequestRef) -> Item? {
        let device = store.loadPending(ref)
        if let draft = device.drafts.first(where: { $0.sync?.job == job }) {
            return .draft(draft.id)
        }
        if let change = device.changes.first(where: { $0.job == job }) {
            return .change(comment: change.comment)
        }
        store.setOwner(nil, ofJob: job)
        return nil
    }

    /// GitHub has it. The device's copy goes; a change made to it while it was on its way follows it now.
    private func landed(_ item: Item, job: String?, on ref: PullRequestRef, detail: PullRequestDetail?) {
        var device = store.loadPending(ref)
        switch item {
        case let .draft(id):
            if let index = device.drafts.firstIndex(where: { $0.id == id }) {
                let draft = device.drafts.remove(at: index)
                let sent = draft.sync?.sent ?? draft.body
                let asLanded = detail?.pendingReview.comments.last { comment in
                    comment.thread == nil && comment.path == draft.path && comment.body == sent
                        && comment.isFile == (draft.isFile == true) && (comment.isFile || comment.line == draft.line)
                }
                if let asLanded, let change = draft.changeOnceLanded(as: asLanded.id) {
                    device.changes.append(change)
                }
            }
        case let .change(comment):
            // One changed again while this was on its way is a newer change, with a send of its own.
            device.changes.removeAll { $0.comment == comment && $0.isSent == true && $0.job == job }
        }
        save(device, for: ref)
        if let detail, detail.pendingReview.isSupported {
            contexts[ref] = Context(pullRequest: detail.id ?? "", comments: detail.pendingReview.comments)
            reconcile(ref)
        }
        changed(ref, detail: detail)
        sync(ref)
    }

    private func refuse(_ item: Item, job: String?, on ref: PullRequestRef, reason: String) -> Refusal {
        var device = store.loadPending(ref)
        var outcome = Refusal.failed
        switch item {
        case let .draft(id):
            guard let index = device.drafts.firstIndex(where: { $0.id == id }) else {
                break
            }
            if device.drafts[index].sync?.isDeleted == true {
                // Deleted while it was on its way, and it never landed: there is nothing left to say.
                device.drafts.remove(at: index)
                outcome = .settled
            } else {
                device.drafts[index].sync = PRDraftSync(failure: reason)
            }
        case let .change(comment):
            let isThisSend = { (change: PRPendingChange) in
                change.comment == comment && change.job == job && change.isSent == true
            }
            guard let index = device.changes.firstIndex(where: isThisSend) else {
                break
            }
            if reason.localizedCaseInsensitiveContains(Self.goneWords) {
                // GitHub wins: the comment was submitted or deleted elsewhere, so the change has nothing to change.
                device.changes.remove(at: index)
                contexts[ref]?.comments.removeAll { $0.id == comment }
                outcome = .settled
            } else {
                device.changes[index].failure = reason
                device.changes[index].job = nil
                device.changes[index].isSent = nil
            }
        }
        save(device, for: ref)
        changed(ref)
        return outcome
    }

    /// Back to waiting: the send did not get through, and nobody refused it.
    private func wait(_ item: Item, job: String?, on ref: PullRequestRef) {
        var device = store.loadPending(ref)
        switch item {
        case let .draft(id):
            if let index = device.drafts.firstIndex(where: { $0.id == id }) {
                if device.drafts[index].sync?.isDeleted == true {
                    device.drafts.remove(at: index)
                } else {
                    device.drafts[index].sync = nil
                }
            }
        case let .change(comment):
            if let index = device.changes.firstIndex(where: { $0.comment == comment && $0.job == job }) {
                device.changes[index].isSent = nil
                device.changes[index].job = nil
            }
        }
        save(device, for: ref)
    }

    // MARK: - The device's copy

    private func change(_ id: UUID, on ref: PullRequestRef, _ change: (inout PRDraftComment) -> Void) {
        var device = store.loadPending(ref)
        guard let index = device.drafts.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&device.drafts[index])
        save(device, for: ref)
    }

    /// Saves the device's state, and forgets the outbox jobs nothing on it waits for any more.
    private func save(_ device: PRPendingDevice, for ref: PullRequestRef) {
        let jobs = { (device: PRPendingDevice) in
            Set(device.drafts.compactMap { $0.sync?.job } + device.changes.compactMap(\.job))
        }
        for job in jobs(store.loadPending(ref)).subtracting(jobs(device)) {
            store.setOwner(nil, ofJob: job)
        }
        store.save(device, for: ref)
    }

    /// GitHub wins for what it has; what is no longer on its way anywhere and not on GitHub goes back to waiting.
    private func reconcile(_ ref: PullRequestRef) {
        guard let context = contexts[ref] else {
            return
        }
        let device = store.loadPending(ref)
        let next = device.reconciled(with: context.comments) { key in isOnItsWay(key, about: ref) }
        if next != device {
            save(next, for: ref)
        }
    }

    private func isOnItsWay(_ key: String, about ref: PullRequestRef) -> Bool {
        guard let model else {
            return false
        }
        return sending[key] != nil || model.queued[key] != nil || model.waiting.contains(key)
            || model.outbox?.holds(job: key, about: ref) == true
    }

    /// True when the host's outbox stopped the job before any of it could have reached the Worker.
    private func stop(_ job: String) async -> Bool {
        guard let model, let outbox = model.outbox, await outbox.cancel(job) else {
            return false
        }
        model.queued[job] = nil
        store.setOwner(nil, ofJob: job)
        return true
    }

    private func hold(_ key: String) {
        sending[key, default: 0] += 1
    }

    private func release(_ key: String) {
        let left = (sending[key] ?? 0) - 1
        sending[key] = left > 0 ? left : nil
    }

    private func changed(_ ref: PullRequestRef, detail: PullRequestDetail? = nil) {
        let screens = (followers[ref] ?? []).compactMap(\.screen)
        followers[ref] = screens.map { Follower(screen: $0) }
        for screen in screens {
            screen.pendingChanged(detail: detail)
        }
    }
}
