import Foundation
@testable import PRHubCore
@testable import PRKit
import Testing

/// The sample PRs' own data agrees with itself: each page says what its row says, and each key line is on its diff.
struct PRHubSampleDataTests {
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

    /// Every sample is a PR on a Worker that reads pending reviews, and one comes with a review begun on github.com:
    /// a comment on a line its diff shows, and one on a whole file.
    @Test func everySampleCarriesThePendingReviewKeyAndOneHasAReviewWaiting() throws {
        var waiting: [PRSampleSet.Sample] = []
        for sample in PRSampleSet.prHub.samples {
            let detail = try PullRequestDetail.decode(Data(sample.detail.utf8))
            #expect(detail.pendingReview.isSupported, "\(sample.row.id)")
            if !detail.pendingReview.comments.isEmpty {
                waiting.append(sample)
            }
        }
        let sample = try #require(waiting.first)
        #expect(waiting.count == 1 && sample.row.id == "acme/web#412")
        let detail = try PullRequestDetail.decode(Data(sample.detail.utf8))
        let rows = DiffRows(
            document: DiffDocument(data: Data(sample.diff.utf8)), threads: [],
            pending: PRPendingDevice().comments(over: detail.pendingReview.comments)
        )
        #expect(detail.pendingReview.comments.count == 2)
        #expect(rows.placed == ["sample-pending-412-1"], "one sits under its line; the page lists the file's")
        #expect(detail.pendingReview.comments[1].isFile)
    }

    @Test func everyKeyLineIsALineItsDiffShows() throws {
        for sample in PRSampleSet.prHub.samples {
            let document = DiffDocument(data: Data(sample.diff.utf8))
            let lines = try JSONDecoder().decode(PRKeyLines.self, from: Data(#require(sample.keyLines).utf8))
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
}
