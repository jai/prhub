import DurableNetworking
import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A sample PR after a write that stayed on the phone (`PRSampleSet.applying`, `PRsModel.sampleWritten`): the PR and
/// its row as GitHub would then show them, when the PR opens again too. Each is a bug the 2026-11-10 bug bash found:
/// the write was said to be posted and then dropped.
@MainActor
struct PRSampleWriteTests {
    private let ref = PullRequestRef(repo: "acme/web", number: 7)

    private static let detail = """
    {"url":"u","state":"open","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,
    "body":"Old words.","additions":0,"deletions":0,"changedFiles":0,"reviewDecision":"APPROVED",
    "mergeState":"CLEAN","reviewers":[{"login":"octocat","avatarUrl":null,"state":"APPROVED"}],
    "labels":[],"checks":[],"comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},
    "title":null}
    """

    private func model(
        list: String = "review", detail: String = PRSampleWriteTests.detail, refusesLinePendingAdds: String? = nil
    ) -> PRsModel {
        let status = PullRequestRow.Status(
            list: list, author: "mona", checks: "passing", review: "approved", merge: "clean", jaiReview: nil,
            jaiReviewedAt: nil
        )
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Add a thing", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: status
        )
        var samples = PRSampleSet(
            samples: [.init(row: row, detail: detail, diff: "", keyLines: nil)], mergedReviewed: [],
            mergedMine: [], answersOnPhone: true
        )
        samples.refusesLinePendingAdds = refusesLinePendingAdds
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        let model = PRsModel(client: client, samples: samples, storage: .inMemory(), network: PRNetwork(isOnline: true))
        model.featureSource = {
            var configuration = PRKitConfiguration.everything
            configuration.login = "octocat"
            return configuration
        }
        return model
    }

    private func reopened(_ model: PRsModel) throws -> PullRequestDetail {
        let row = try #require(model.rows.first ?? model.merged.values.joined().first)
        return try #require(model.session(for: row).content?.detail)
    }

    @Test func aChangeRequestReplacesTheApprovalOnThePRAndItsRow() async throws {
        let model = model()
        let write = PRWrite.review(.requestChanges, body: "Add a test.", commit: "h", comments: [])
        let detail = try #require(try await model.write(write, to: ref).posted)
        #expect(detail.reviewDecision == "CHANGES_REQUESTED")
        #expect(detail.reviewers?.map(\.state) == ["CHANGES_REQUESTED"])
        #expect(model.rows.first?.status?.review == "changes_requested")
        #expect(try reopened(model).reviewDecision == "CHANGES_REQUESTED")
    }

    @Test func anApprovalIsTheDecisionAndACommentLeavesIt() async throws {
        let model = model()
        _ = try await model.write(.review(.requestChanges, body: "", commit: "h", comments: []), to: ref)
        _ = try await model.write(.review(.comment, body: "A thought.", commit: "h", comments: []), to: ref)
        #expect(model.rows.first?.status?.review == "changes_requested")
        let detail = try #require(
            try await model.write(.review(.approve, body: "", commit: "h", comments: []), to: ref).posted
        )
        #expect(detail.reviewDecision == "APPROVED" && detail.reviews.nodes.count == 3)
        #expect(model.rows.first?.status?.review == "approved")
    }

    @Test func aLineCommentStartsAThreadThatTakesAReplyAndResolves() async throws {
        let model = model()
        let line = PRWrite.line(path: "README.md", line: 3, side: .right, body: "Which step?", commit: "h")
        let thread = try #require(try await model.write(line, to: ref).posted?.reviewThreads.nodes.first)
        #expect(thread.path == "README.md" && thread.line == 3 && thread.diffSide == "RIGHT")
        #expect(thread.comments.nodes.map(\.body) == ["Which step?"])
        _ = try await model.write(.reply(thread: thread.id, body: "The second."), to: ref)
        _ = try await model.write(.resolve(thread: thread.id, resolved: true), to: ref)
        let after = try #require(try reopened(model).reviewThreads.nodes.first)
        #expect(after.isResolved && after.comments.nodes.map(\.body) == ["Which step?", "The second."])
    }

    @Test func aReviewsLineCommentsBecomeThreads() async throws {
        let model = model()
        let draft = PRDraftComment(id: UUID(), path: "a.swift", line: 9, side: .left, body: "Why removed?")
        let detail = try #require(
            try await model.write(.review(.comment, body: "", commit: "h", comments: [draft]), to: ref).posted
        )
        #expect(detail.reviewThreads.nodes.map(\.path) == ["a.swift"])
        #expect(detail.reviewThreads.nodes.first?.diffSide == "LEFT")
    }

    @Test func anEditedDescriptionIsKept() async throws {
        let model = model()
        _ = try await model.write(.editBody("New words.", base: "Old words."), to: ref)
        #expect(try reopened(model).body == "New words.")
    }

    @Test func aMergedPRLeavesTheOpenListForItsPagesMergedOnes() async throws {
        let model = model(list: "mine")
        let detail = try #require(try await model.write(.merge(method: "merge", commit: "h"), to: ref).posted)
        #expect(detail.state == "merged")
        #expect(model.rows.isEmpty)
        #expect(model.merged[.mine]?.map(\.isMerged) == [true])
        // Opening the merged list again keeps it, and the PR still opens, merged, and takes a comment.
        await model.loadMerged(on: .mine)
        #expect(model.merged[.mine]?.count == 1 && model.merged[.review] == nil)
        #expect(try reopened(model).state == "merged")
        #expect(try await model.write(.comment(body: "Thanks."), to: ref).posted?.comments.nodes.count == 1)
    }

    // MARK: - A pending review on a sample PR

    private func pendingModel(refusing refusal: String? = nil) -> PRsModel {
        model(
            detail: Self.detail.replacing(#""title":null}"#, with: #""title":null,"pendingReview":null}"#),
            refusesLinePendingAdds: refusal
        )
    }

    @Test func aSampleKeepsAPendingReviewAsGitHubWould() async throws {
        let model = pendingModel()
        let add = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: 3, side: .right, body: "Which step?")
        let added = try #require(try await model.write(add, to: ref).posted?.pendingReview.comments)
        #expect(added.map(\.body) == ["Which step?"] && added[0].line == 3 && !added[0].isFile)
        let onFile = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: nil, side: .right, body: "Add a title.")
        _ = try await model.write(onFile, to: ref)
        _ = try await model.write(.pendingEdit(comment: added[0].id, body: "Which of the steps?"), to: ref)
        let held = try reopened(model).pendingReview.comments
        #expect(held.map(\.body) == ["Which of the steps?", "Add a title."], "kept when the PR opens again")
        #expect(held[1].isFile && held[1].line == nil)
        let left = try #require(try await model.write(.pendingDelete(comment: held[1].id), to: ref).posted)
        #expect(left.pendingReview.comments.map(\.id) == [held[0].id])
        #expect(left.reviewThreads.nodes.isEmpty, "nothing is posted until the review is")
    }

    @Test func submittingItPostsTheReviewWithItsCommentsAndLeavesNoneWaiting() async throws {
        let model = pendingModel()
        _ = try await model.write(.pendingAdd(pullRequest: "", path: "README.md", line: 3, side: .right, body: "Which step?"), to: ref)
        let detail = try #require(try await model.write(.pendingSubmit(.requestChanges, body: "Add a test."), to: ref).posted)
        #expect(detail.pendingReview == PRPendingReviewAnswer.none)
        #expect(detail.reviewDecision == "CHANGES_REQUESTED" && detail.reviews.nodes.last?.body == "Add a test.")
        #expect(detail.reviewThreads.nodes.map(\.line) == [3])
        #expect(detail.reviewThreads.nodes.first?.comments.nodes.map(\.body) == ["Which step?"])
        #expect(model.rows.first?.status?.review == "changes_requested")
    }

    @Test func theLastCommentsRemovalAndADiscardEndThePendingReview() async throws {
        let model = pendingModel()
        let add = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: 3, side: .right, body: "Which step?")
        let added = try #require(try await model.write(add, to: ref).posted?.pendingReview.comments.first)
        let emptied = try #require(try await model.write(.pendingDelete(comment: added.id), to: ref).posted)
        #expect(emptied.pendingReview == PRPendingReviewAnswer.none)
        _ = try await model.write(add, to: ref)
        let discarded = try #require(try await model.write(.pendingDiscard, to: ref).posted)
        #expect(discarded.pendingReview == PRPendingReviewAnswer.none && discarded.reviewThreads.nodes.isEmpty)
    }

    /// A sample detail without the key is an older Worker's: a pending write changes nothing, and nothing is invented.
    @Test func aSampleWithoutTheKeyTakesNoPendingReview() async throws {
        let model = model()
        let add = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: 3, side: .right, body: "Which step?")
        #expect(try await model.write(add, to: ref).posted?.pendingReview == .unsupported)
    }

    /// A UI test's way to a failed pending comment: a line's add is refused, a file's is taken.
    @Test func aSampleSetCanRefuseAPendingCommentOnALine() async throws {
        let model = pendingModel(refusing: "Its line may no longer be in the diff.")
        let onLine = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: 3, side: .right, body: "Which step?")
        await #expect(throws: PRWorkerError.refused("Its line may no longer be in the diff.", isPermanent: true)) {
            try await model.write(onLine, to: ref)
        }
        let onFile = PRWrite.pendingAdd(pullRequest: "", path: "README.md", line: nil, side: .right, body: "Line 3: Which step?")
        #expect(try await model.write(onFile, to: ref).posted?.pendingReview.comments.map(\.isFile) == [true])
    }
}
