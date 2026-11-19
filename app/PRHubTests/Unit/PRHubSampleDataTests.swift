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
