import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing

/// PRHub's "Try with sample PRs" (`PRHubSamples.swift`): made-up PRs that open, show their diff and key lines, and take
/// a review, with nothing sent anywhere.
@MainActor
struct PRHubSamplesTests {
    private let resources = IntegrationResources()
    private struct RecordingTransport: HTTPTransport {
        let calls: Shared<Int>

        func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
            calls.with { $0 += 1 }
            throw URLError(.unsupportedURL)
        }
    }

    private func makeModel() -> PRsModel {
        let model = PRsModel(
            client: PRViewerClient(access: .offline), samples: .prHub, directory: resources.directory(),
            defaults: resources.defaults(), network: PRNetwork(isOnline: true), draftDirectory: resources.directory()
        )
        let config = DeviceConfig(features: [.keyLines], login: PRSampleSet.prHubLogin)
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)

    @Test func theSamplesFillBothListsWithMadeUpRepos() {
        let model = makeModel()
        #expect(model.rows.filter { PRListPage.review.holds($0) }.count == 4)
        #expect(model.rows.filter { PRListPage.mine.holds($0) }.count == 2)
        for row in model.rows {
            #expect(row.org == "acme" || row.org == "octocat", "\(row.repo)")
        }
    }

    @Test func everySampleOpensWithItsDescriptionAndDiff() throws {
        let model = makeModel()
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

    @Test func keyLinesAnswerOnThePhoneAtAnyContext() async throws {
        let model = makeModel()
        var events: [PRKitEvent] = []
        model.onEvent = { events.append($0) }
        let lines: PRKeyLines = try await model.aiAnswer(
            "key-lines", ref: Self.checkout, head: "sample-412", context: 10, retry: false
        )
        #expect(lines.items.count == 2)
        await #expect(throws: PRLocalRefusal.sampleAI) {
            let _: PRRewrite = try await model.aiAnswer("rewrite", ref: Self.checkout, head: "sample-412", retry: true)
        }
        #expect(events.count == 2)
        guard case let .aiAnswered(.keyLines, .done, keyLinesMilliseconds, true) = events.first,
              case let .aiAnswered(.rewrite, .failed(.local), rewriteMilliseconds, nil) = events.last
        else {
            Issue.record("sample answers must report their result and the checkout description's AI slop")
            return
        }
        #expect(keyLinesMilliseconds >= 0 && rewriteMilliseconds >= 0)
    }

    @Test func aReviewStaysOnThePhoneAndSaysSo() async throws {
        let model = makeModel()
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
        let model = makeModel()
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
        let calls = Shared(0)
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "test" }, discard: {})
        let model = PRsModel(
            client: PRViewerClient(access: access, transport: RecordingTransport(calls: calls)), samples: .prHub,
            directory: resources.directory(), defaults: resources.defaults(), network: PRNetwork(isOnline: true),
            draftDirectory: resources.directory()
        )
        #expect(await model.refresh(.foreground) == .unchanged)
        await model.loadMerged(on: .review)
        #expect(model.merged[.review]?.isEmpty == true)
        _ = try await model.write(.comment(body: "Stayed here"), to: Self.checkout)
        let _: PRKeyLines = try await model.aiAnswer("key-lines", ref: Self.checkout, head: "sample-412", retry: false)
        #expect(calls.with { $0 } == 0, "sample reads, writes and AI must not reach the configured transport")
    }

    @Test func aSetThatDoesNotAnswerOnThePhoneRefusesWrites() async throws {
        let refusing = PRSampleSet(
            samples: PRSampleSet.prHub.samples, mergedReviewed: [], mergedMine: [], answersOnPhone: false
        )
        let model = PRsModel(
            client: PRViewerClient(access: .offline), samples: refusing, directory: resources.directory(),
            defaults: resources.defaults(), network: PRNetwork(isOnline: true), draftDirectory: resources.directory()
        )
        await #expect(throws: PRLocalRefusal.sampleWrite) {
            try await model.write(.comment(body: "x"), to: Self.checkout)
        }
        #expect(model.writeNotice == nil)
    }

    @Test func connectYourOwnWorkerLeavesNoSampleSettingBehind() {
        let defaults = resources.defaults()
        let environment = resources.environment(defaults: defaults)
        environment.startSample()
        #expect(environment.sample?.isSample == true)
        #expect(environment.sample?.connection.showsOnboarding == false)
        defaults.set("acme,octocat|", forKey: "prOrgFilter")
        environment.endSample()
        #expect(environment.sample == nil)
        #expect(defaults.string(forKey: "prOrgFilter") == nil)
    }
}
