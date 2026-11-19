import DurableNetworking
import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import PRKitTestSupport
import Testing

/// PRHub's "Try with sample PRs" (`PRHubSamples.swift`): made-up PRs that open, show their diff and key lines, and take
/// a review, with nothing sent anywhere.
@MainActor
struct PRHubSamplesTests {
    private let resources = UnitResources()
    private func makeModel() -> PRsModel {
        let model = PRsModel(
            client: PRViewerClient(access: .offline, transport: UnexpectedTransport()), samples: .prHub,
            storage: .inMemory(), network: PRNetwork(isOnline: true)
        )
        let config = DeviceConfig(features: [.keyLines], login: PRSampleSet.prHubLogin)
        model.featureSource = { PRHubPRHost.configuration(config) }
        return model
    }

    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)

    @Test func theSamplesFillBothListsWithMadeUpRepos() {
        let model = makeModel()
        #expect(PRSampleSet.prHub.answersOnPhone)
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

    @Test func connectYourOwnWorkerLeavesNoSampleSettingBehind() {
        let defaults = resources.defaults()
        let environment = resources.environment(defaults: defaults)
        environment.startSample()
        #expect(environment.sample?.isSample == true)
        #expect(environment.sample?.connection.showsOnboarding == false)
        defaults.set("acme,octocat|", forKey: "prOrgFilter")
        environment.endSample()
        #expect(environment.sample == nil)
        #expect(defaults.object(forKey: "prOrgFilter") == nil)
    }
}
