import Foundation
import Testing
@testable import PRHub
@testable import PRKit

/// PRHub's "Try with sample PRs" (`PRHubSamples.swift`): made-up PRs that open, show their diff and key lines, and take
/// a review, with nothing sent anywhere.
@MainActor
@Suite(.serialized)
struct PRHubSamplesTests {
    private static func model() -> PRsModel {
        let model = PRsModel(client: PRViewerClient(access: .offline), samples: .prHub)
        let config = DeviceConfig(features: [.keyLines], login: PRSampleSet.prHubLogin)
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)

    @Test func theSamplesFillBothListsWithMadeUpRepos() {
        let model = Self.model()
        #expect(model.rows.filter { PRListPage.review.holds($0) }.count == 4)
        #expect(model.rows.filter { PRListPage.mine.holds($0) }.count == 2)
        for row in model.rows {
            #expect(row.org == "acme" || row.org == "octocat", "\(row.repo)")
        }
    }

    @Test func everySampleOpensWithItsDescriptionAndDiff() throws {
        let model = Self.model()
        for row in model.rows {
            let session = model.session(for: row)
            let content = try #require(session.content, "\(row.id) opens from the phone")
            #expect(content.detail.title == row.title)
            guard case let .document(document, _) = content.diff else {
                Issue.record("\(row.id) has no diff")
                continue
            }
            #expect(!document.files.isEmpty)
        }
    }

    /// The bug bash's "changes requested" row opened a page that said "Needs review", and so did a PR needing none.
    @Test func everySamplesPageSaysWhatItsRowSaysOfTheReview() throws {
        let decisions = ["approved": "APPROVED", "changes_requested": "CHANGES_REQUESTED", "required": "REVIEW_REQUIRED"]
        for sample in PRSampleSet.prHub.samples {
            let detail = try PullRequestDetail.decode(Data(sample.detail.utf8))
            let review = try #require(sample.row.status?.review)
            #expect(detail.reviewDecision == decisions[review], "\(sample.row.id) \(review)")
            if let mine = sample.row.status?.jaiReview {
                #expect(detail.reviews.nodes.last?.state == decisions[mine], "\(sample.row.id)")
            }
        }
    }

    @Test func everyKeyLineIsALineItsDiffShows() throws {
        for sample in PRSampleSet.prHub.samples {
            let document = DiffDocument(data: Data(sample.diff.utf8))
            let lines = try JSONDecoder().decode(PRKeyLines.self, from: Data(try #require(sample.keyLines).utf8))
            #expect(!lines.items.isEmpty)
            for item in lines.items {
                let shown = document.lines.contains {
                    document.files.indices.contains($0.file) && document.files[$0.file] == item.path
                        && $0.newLine == item.line
                }
                #expect(shown, "\(sample.row.id) \(item.path):\(item.line)")
            }
        }
    }

    @Test func keyLinesAnswerOnThePhoneAtAnyContext() async throws {
        let model = Self.model()
        let lines: PRKeyLines = try await model.aiAnswer(
            "key-lines", ref: Self.checkout, head: "sample-412", context: 10, retry: false
        )
        #expect(lines.items.count == 2)
        await #expect(throws: PRLocalRefusal.sampleAI) {
            let _: PRRewrite = try await model.aiAnswer("rewrite", ref: Self.checkout, head: "sample-412", retry: true)
        }
    }

    @Test func aReviewStaysOnThePhoneAndSaysSo() async throws {
        let model = Self.model()
        let detail = try #require(try await model.write(
            .review(.approve, body: "Ship it", commit: "sample-412", comments: []), to: Self.checkout
        ).posted)
        let review = try #require(detail.reviews.nodes.last)
        #expect(review.state == "APPROVED" && review.body == "Ship it")
        #expect(review.author?.login == PRSampleSet.prHubLogin)
        #expect(model.writeNotice == .sampleOnly)
        // The PR shows the review when it opens again.
        let row = try #require(model.rows.first { $0.id == "acme/web#412" })
        #expect(model.session(for: row).content?.detail.reviews.nodes.last?.body == "Ship it")
    }

    @Test func aCommentJoinsTheConversation() async throws {
        let model = Self.model()
        let detail = try #require(
            try await model.write(.comment(body: "Nice one"), to: PullRequestRef(repo: "acme/api", number: 88)).posted
        )
        #expect(detail.comments.nodes.last?.body == "Nice one")
    }

    @Test func nothingIsSentFromTheSamples() async throws {
        let client = PRViewerClient(access: .offline)
        await #expect(throws: PRWorkerError.notPaired) {
            try await client.outboxRequest(path: "prs/acme/web/412/write", body: Data("{}".utf8))
        }
        let model = Self.model()
        #expect(await model.refresh(.foreground) == .unchanged)
        await model.loadMerged(on: .review)
        #expect(model.merged[.review]?.isEmpty == true)
    }

    @Test func aSetThatDoesNotAnswerOnThePhoneRefusesWrites() async throws {
        let refusing = PRSampleSet(
            samples: PRSampleSet.prHub.samples, mergedReviewed: [], mergedMine: [], answersOnPhone: false
        )
        let model = PRsModel(client: PRViewerClient(access: .offline), samples: refusing)
        await #expect(throws: PRLocalRefusal.sampleWrite) {
            try await model.write(.comment(body: "x"), to: Self.checkout)
        }
        #expect(model.writeNotice == nil)
    }

    @Test func connectYourOwnWorkerLeavesNoSampleSettingBehind() {
        let environment = PRHubEnvironment(
            connection: PRHubEnvironment.sample().connection
        )
        environment.startSample()
        #expect(environment.sample?.isSample == true)
        #expect(environment.sample?.connection.showsOnboarding == false)
        UserDefaults.standard.set("acme,octocat|", forKey: "prOrgFilter")
        environment.endSample()
        #expect(environment.sample == nil)
        #expect(UserDefaults.standard.string(forKey: "prOrgFilter") == nil)
    }
}
