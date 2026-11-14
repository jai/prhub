import Foundation
import Testing
@testable import PRKit

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

    private func model(list: String = "review") -> PRsModel {
        let status = PullRequestRow.Status(
            list: list, author: "mona", checks: "passing", review: "approved", merge: "clean", jaiReview: nil,
            jaiReviewedAt: nil
        )
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Add a thing", head: "h", revision: "sample", diff: .ready,
            detail: "sample", status: status
        )
        let samples = PRSampleSet(
            samples: [.init(row: row, detail: Self.detail, diff: "", keyLines: nil)], mergedReviewed: [],
            mergedMine: [], answersOnPhone: true
        )
        let directory = URL.temporaryDirectory.appending(path: "pr-sample-writes-\(UUID().uuidString)")
        let client = PRViewerClient(access: .offline, isInForeground: { false })
        let model = PRsModel(client: client, samples: samples, directory: directory)
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
}
