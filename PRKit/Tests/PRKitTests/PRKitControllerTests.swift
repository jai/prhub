import Foundation
import Testing
@testable import PRKit

/// The host's way in and out: what it gives the kit, what it asks of it, and what the kit tells it.
@MainActor
struct PRKitControllerTests {
    @MainActor
    final class Host: PRKitHost {
        let access = PRViewerAccess.offline
        var configuration = PRKitConfiguration.everything
        var outbox: (any PRKitOutbox)? { nil }
        let apnsEnvironment = "sandbox"
        var samples: PRSampleSet?
        let launchOptions = PRKitLaunchOptions.none
        private(set) var events: [PRKitEvent] = []

        init(samples: PRSampleSet? = nil) {
            self.samples = samples
        }

        func isInForeground() async -> Bool { false }
        func log(_ line: String) {}
        func receive(_ event: PRKitEvent) { events.append(event) }
    }

    @Test func textThatNamesAPRShowsItAndOtherTextDoesNot() {
        let kit = PRKitController(host: Host())
        #expect(!kit.open(text: "not a PR"))
        #expect(kit.navigation.pendingPullRequest == nil)
        #expect(kit.open(text: "https://github.com/jai/agent-pager/pull/28"))
        #expect(kit.navigation.pendingPullRequest == PullRequestRef(repo: "jai/agent-pager", number: 28))
    }

    @Test func theScreensFollowTheHostsConfigurationAsItChanges() {
        let host = Host()
        let kit = PRKitController(host: host)
        let ref = PullRequestRef(repo: "acme/api", number: 7)
        #expect(kit.model.session(for: ref).offersAsk)
        host.configuration = PRKitConfiguration(features: [.keyLines], orgDefault: .everyOwner)
        let session = kit.model.session(for: ref)
        #expect(!session.offersAsk && session.offersKeyLines)
        #expect(kit.model.orgDefault == .everyOwner)
    }

    @Test func theHostHearsOfEachOpenAndEachSync() async {
        let host = Host(samples: PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true))
        let kit = PRKitController(host: host)
        _ = kit.model.session(for: PullRequestRef(repo: "acme/api", number: 7))
        #expect(await kit.refresh(.pull) == .unchanged)
        #expect(host.events == [.opened(PullRequestRef(repo: "acme/api", number: 7)), .synced(.pull, .unchanged)])
    }

    @Test func aRefusalAfterTheScreenHasGoneIsShownAndTold() {
        let host = Host()
        let kit = PRKitController(host: host)
        kit.outboxRefused(id: "item-1", reason: "Pull request is locked")
        #expect(kit.model.refusedWrite == "GitHub refused a write: Pull request is locked")
        #expect(host.events == [.writeRefused("GitHub refused a write: Pull request is locked")])
    }
}
