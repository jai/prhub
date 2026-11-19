import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

/// A file marked viewed from the keyboard or twice, on a PR read from the Worker's contract fixture.
@MainActor
struct PRNavigationTests {
    private let storage = TestStorage()
    private let ref = PullRequestRef(repo: "acme/api", number: 7)

    private func makeModel(_ samples: PRSampleSet) -> PRsModel {
        PRsModel(
            client: PRViewerClient(access: .offline, transport: UnexpectedTransport()), samples: samples,
            directory: storage.directory, defaults: storage.defaults, network: PRNetwork(isOnline: true),
            draftDirectory: storage.draftDirectory
        )
    }

    @Test func viewedFromTheKeyboardMarksTheFileOnTop() throws {
        let samples = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: false)
        let model = makeModel(samples)
        let text = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
        let document = DiffDocument(data: Data(text.utf8))
        let detail = try PullRequestDetail.decode(FixtureContractTests.data("detail.json"))
        let session = PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: document), tappedAt: 0, model: model
        )
        let files = DiffRows(document: document, threads: []).files
        let before = session.viewedFiles
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before.union(["a"]))
        session.toggleViewedOnTopFile(in: files)
        #expect(session.viewedFiles == before)
    }

    @Test func markingAFileViewedTwiceKeepsItViewed() throws {
        let samples = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: false)
        let model = makeModel(samples)
        let document = DiffDocument(data: Data("diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+y\n".utf8))
        let detail = try PullRequestDetail.decode(FixtureContractTests.data("detail.json"))
        let session = PRSession(
            ref: ref, title: nil, content: PRContent(detail: detail, document: document), tappedAt: 0, model: model
        )
        session.setViewed(true, path: "a")
        session.setViewed(true, path: "a")
        #expect(session.viewedFiles.contains("a"))
        session.setViewed(false, path: "a")
        session.setViewed(false, path: "a")
        #expect(!session.viewedFiles.contains("a"))
    }
}
