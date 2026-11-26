import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// The one list of a PR's pending comments (`PRPendingDevice`): GitHub's pending review with this device's unsent
/// changes on it, then what the device has not got to GitHub yet. And what the device keeps once GitHub is read again.
struct PRPendingListTests {
    private let first = PRPendingReview.Comment(id: "PRRC_1", path: "src/a.ts", line: 12, body: "Why twice?")
    private let second = PRPendingReview.Comment(id: "PRRC_2", path: "src/a.ts", line: nil, body: "Add a test.", isFile: true)

    private func draft(_ body: String, line: Int = 12, sync: PRDraftSync? = nil) -> PRDraftComment {
        PRDraftComment(id: UUID(), path: "src/a.ts", line: line, side: .right, body: body, sync: sync)
    }

    @Test func gitHubsCommentsComeFirstThenTheDevices() {
        let mine = draft("Mine")
        let list = PRPendingDevice(drafts: [mine]).comments(over: [first, second])
        #expect(list.map(\.id) == ["PRRC_1", "PRRC_2", mine.id.uuidString])
        #expect(list.map(\.sync) == [.synced, .synced, .waiting])
        #expect(list.map(\.origin) == [.github("PRRC_1"), .github("PRRC_2"), .device(mine)])
        #expect(list[1].isFile && list[1].line == nil && list[1].location == "src/a.ts")
        #expect(list[0].location == "src/a.ts:12")
    }

    @Test func anUnsentEditShowsItsWordsAndAnUnsentDeleteHidesTheComment() {
        let device = PRPendingDevice(changes: [
            PRPendingChange(comment: "PRRC_1", body: "Why two times?"), PRPendingChange(comment: "PRRC_2", body: nil),
        ])
        let list = device.comments(over: [first, second])
        #expect(list.map(\.body) == ["Why two times?"])
        #expect(list.map(\.sync) == [.waiting])
    }

    @Test func aRefusedChangeStaysOnItsCommentWithTheReason() {
        let device = PRPendingDevice(changes: [
            PRPendingChange(comment: "PRRC_1", body: "New", failure: "Body is too long"),
            PRPendingChange(comment: "PRRC_2", body: nil, failure: "Not allowed"),
        ])
        let list = device.comments(over: [first, second])
        #expect(list.map(\.sync) == [.failed("Body is too long"), .failed("Not allowed")])
        #expect(list.allSatisfy { $0.goesWithReview }, "GitHub still has both: the review carries them as GitHub has them")
    }

    @Test func aRefusedDeviceCommentIsFailedAndGoesWithNoReview() {
        let refused = draft("Mine", sync: PRDraftSync(failure: "Its line may no longer be in the diff."))
        let list = PRPendingDevice(drafts: [refused]).comments(over: [])
        #expect(list.map(\.sync) == [.failed("Its line may no longer be in the diff.")])
        #expect(list[0].goesWithReview == false)
    }

    @Test func aCommentDeletedWhileItsAddWasOnItsWayIsNotShown() {
        let deleted = draft("Mine", sync: PRDraftSync(job: "job-1", sent: "Mine", isDeleted: true))
        #expect(PRPendingDevice(drafts: [deleted]).comments(over: [first]).map(\.id) == ["PRRC_1"])
    }

    // MARK: - Once GitHub is read again

    @Test func aSentCommentGitHubShowsHasLandedAndLeavesTheDevice() {
        let sent = draft("Why twice?", sync: PRDraftSync(job: "job-1", sent: "Why twice?"))
        let next = PRPendingDevice(drafts: [sent]).reconciled(with: [first]) { _ in false }
        #expect(next.isEmpty)
        #expect(next.comments(over: [first]).map(\.id) == ["PRRC_1"], "once, not twice")
    }

    @Test func aSentCommentThatIsOnNoPhoneAndNotOnGitHubWaitsAgain() {
        let sent = draft("Lost?", sync: PRDraftSync(job: "job-1", sent: "Lost?"))
        let next = PRPendingDevice(drafts: [sent]).reconciled(with: [first]) { _ in false }
        #expect(next.drafts.map(\.body) == ["Lost?"])
        #expect(next.drafts[0].isUnsent, "it is sent again, never lost")
    }

    @Test func aCommentStillOnItsWayIsLeftAlone() {
        let sent = draft("Why twice?", sync: PRDraftSync(job: "job-1", sent: "Why twice?"))
        let device = PRPendingDevice(drafts: [sent])
        #expect(device.reconciled(with: []) { $0 == "job-1" } == device)
    }

    @Test func aCommentChangedWhileOnItsWayIsEditedOnGitHubOnceItHasLanded() {
        var sent = draft("New words", sync: PRDraftSync(job: "job-1", sent: "Why twice?"))
        var next = PRPendingDevice(drafts: [sent]).reconciled(with: [first]) { _ in false }
        #expect(next == PRPendingDevice(changes: [PRPendingChange(comment: "PRRC_1", body: "New words")]))
        sent.sync?.isDeleted = true
        next = PRPendingDevice(drafts: [sent]).reconciled(with: [first]) { _ in false }
        #expect(next == PRPendingDevice(changes: [PRPendingChange(comment: "PRRC_1", body: nil)]))
    }

    @Test func gitHubWinsForWhatItHas() {
        let device = PRPendingDevice(changes: [
            // GitHub already shows these words.
            PRPendingChange(comment: "PRRC_1", body: "Why twice?", isSent: true),
            // Submitted or deleted elsewhere: nothing is left to change.
            PRPendingChange(comment: "PRRC_9", body: "Gone"),
            // Not on GitHub yet, and its send is on no phone: it waits again.
            PRPendingChange(comment: "PRRC_2", body: "Add two tests.", job: "job-3", isSent: true),
        ])
        let next = device.reconciled(with: [first, second]) { _ in false }
        #expect(next.changes == [PRPendingChange(comment: "PRRC_2", body: "Add two tests.")])
        #expect(next.changes[0].isUnsent)
    }

    // MARK: - On disk

    @Test func aDraftAnOlderVersionStoredLoadsAsOneNotSentYet() throws {
        let files = InMemoryFileStore()
        let ref = PullRequestRef(repo: "acme/api", number: 7)
        let old = #"[{"id":"7B0E8D6C-3C1B-4C55-9B62-0C1D0E5B7A11","path":"src/a.ts","line":12,"side":"RIGHT","body":"Old one"}]"#
        try files.write(Data(old.utf8), to: "acme__api__7.json")
        let loaded = PRDraftStore(store: files).loadPending(ref)
        #expect(loaded.drafts.map(\.body) == ["Old one"])
        #expect(loaded.drafts[0].isUnsent && loaded.drafts[0].isFile == nil && loaded.changes.isEmpty)
    }

    @Test func theDevicesStateAndEachJobsPROutliveTheStore() {
        let files = InMemoryFileStore()
        let ref = PullRequestRef(repo: "acme/api", number: 7)
        let device = PRPendingDevice(
            drafts: [draft("Mine", sync: PRDraftSync(job: "job-1", sent: "Mine"))],
            changes: [PRPendingChange(comment: "PRRC_1", body: nil, failure: "Not allowed")]
        )
        PRDraftStore(store: files).save(device, for: ref)
        PRDraftStore(store: files).setOwner(ref, ofJob: "job-1")
        let again = PRDraftStore(store: files)
        #expect(again.loadPending(ref) == device)
        #expect(again.owner(ofJob: "job-1") == ref && again.owner(ofJob: "job-2") == nil)
        again.setOwner(nil, ofJob: "job-1")
        again.save(PRPendingDevice(), for: ref)
        #expect(files.names().isEmpty, "nothing is left once GitHub has it all")
    }

    // MARK: - What goes to the Worker

    private func payload(_ write: PRWrite) -> [String: AnyHashable]? {
        (try? JSONEncoder().encode(write)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: AnyHashable] }
    }

    @Test func eachPendingWriteCarriesWhatTheWorkerReadsAndNothingElse() {
        #expect(payload(.pendingAdd(pullRequest: "PR_1", path: "src/a.ts", line: 12, side: .left, body: "Why?")) == [
            "kind": "pending_add", "pullRequest": "PR_1", "path": "src/a.ts", "line": 12, "side": "LEFT", "body": "Why?",
        ])
        #expect(payload(.pendingAdd(pullRequest: "PR_1", path: "src/a.ts", line: nil, side: .right, body: "Why?")) == [
            "kind": "pending_add", "pullRequest": "PR_1", "path": "src/a.ts", "file": true, "body": "Why?",
        ])
        #expect(payload(.pendingEdit(comment: "PRRC_1", body: "New")) == [
            "kind": "pending_edit", "comment": "PRRC_1", "body": "New",
        ])
        #expect(payload(.pendingDelete(comment: "PRRC_1")) == ["kind": "pending_delete", "comment": "PRRC_1"])
        #expect(payload(.pendingSubmit(.requestChanges, body: "Not yet.")) == [
            "kind": "pending_submit", "event": "REQUEST_CHANGES", "body": "Not yet.",
        ])
        #expect(payload(.pendingDiscard) == ["kind": "pending_discard"])
    }

    @Test func aPendingWriteIsToldToTheHostByWhatItDoes() {
        #expect(PRWriteKind(.pendingAdd(pullRequest: "p", path: "f", line: 1, side: .right, body: "b")) == .pendingAdd)
        #expect(PRWriteKind(.pendingEdit(comment: "c", body: "b")) == .pendingEdit)
        #expect(PRWriteKind(.pendingDelete(comment: "c")) == .pendingDelete)
        #expect(PRWriteKind(.pendingDiscard) == .pendingDiscard)
        #expect(PRWriteKind(.pendingSubmit(.approve, body: "")) == .approve)
        #expect(PRWriteKind(.pendingSubmit(.requestChanges, body: "")) == .requestChanges)
        #expect(PRWriteKind(.pendingSubmit(.comment, body: "")) == .review)
    }

    // MARK: - Words

    @Test func theLineBoxAlwaysAddsToTheOneReviewGitHubHolds() {
        #expect(PRPendingWords.addTitle(usesPendingReview: true, hasPending: false) == "Add to review")
        #expect(PRPendingWords.addTitle(usesPendingReview: true, hasPending: true) == "Add to review")
        // A Worker without pending reviews: the first comment starts the review, as before.
        #expect(PRPendingWords.addTitle(usesPendingReview: false, hasPending: false) == "Start review")
        #expect(PRPendingWords.addTitle(usesPendingReview: false, hasPending: true) == "Add to review")
    }

    @Test func theReviewSaysWhatGoesWithItAndWhatWillNot() {
        #expect(PRPendingWords.going(1) == "1 pending comment will go with your review")
        #expect(PRPendingWords.going(3) == "3 pending comments will go with your review")
        #expect(PRPendingWords.refused(comments: 0, changes: 0) == nil)
        #expect(PRPendingWords.refused(comments: 1, changes: 0)?.contains("will not go with your review") == true)
        #expect(PRPendingWords.refused(comments: 0, changes: 2)?.contains("as GitHub has them") == true)
    }
}
