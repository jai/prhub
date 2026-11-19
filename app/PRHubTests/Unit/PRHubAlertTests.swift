import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import PRKitTestSupport
import Testing
import UserNotifications

/// A tapped pr-worker alert opens its PR (docs/api.md, "Alerts"), and the one offer to turn alerts on.
@MainActor
struct PRHubAlertTests {
    private let resources = UnitResources()
    private static let ref = PullRequestRef(repo: "acme/app", number: 7)

    @Test func anAlertOpensNothingDuringTheSamples() {
        let sink = AnalyticsTests.RecordingAnalytics()
        let environment = resources.sample(usage: resources.usage(sink))
        environment.navigation.selectedTab = .settings
        environment.openAlert(Self.ref)
        #expect(environment.navigation.selectedTab == .settings)
        #expect(environment.prs.navigation.pending == nil)
        #expect(sink.events == [.alertIgnored(.samples)])
    }

    @Test func anAlertThatOpensNothingSaysWhy() {
        let sink = AnalyticsTests.RecordingAnalytics()
        let environment = resources.environment(usage: resources.usage(sink))
        environment.startSample()
        environment.navigation.selectedTab = .settings
        environment.openAlert(Self.ref)
        #expect(environment.navigation.selectedTab == .settings)
        #expect(environment.prs.navigation.pending == nil)
        #expect(environment.sample?.prs.navigation.pending == nil)
        #expect(sink.events == [.onboardingPathChosen(.samples), .alertIgnored(.samples)])
    }

    @Test func aPairedWorkerAlertSelectsThePRsTabAndOpensItsPR() {
        let environment = resources.environment()
        environment.navigation.selectedTab = .settings
        environment.openAlert(Self.ref)
        #expect(environment.navigation.selectedTab == .prs)
        #expect(environment.prs.navigation.pending?.link.ref == Self.ref)
    }

    // MARK: - The offer to turn alerts on

    private func permission(
        _ status: UNAuthorizationStatus, asked: Shared<Int> = Shared(0)
    ) -> (PRHubAlertPermission, InMemoryKeyValueStore) {
        let defaults = resources.defaults()
        let state = Shared(status)
        let center = PRHubAlertPermission.Center(
            status: { state.with { $0 } },
            request: {
                asked.with { $0 += 1 }
                state.with { $0 = .authorized }
                return true
            }
        )
        return (PRHubAlertPermission(center: center, defaults: defaults), defaults)
    }

    @Test func aWorkerThatPushesIsOfferedAlertsOnceAndTurnOnAsksTheSystem() async {
        let asked = Shared(0)
        let (permission, _) = permission(.notDetermined, asked: asked)
        await permission.offerIfDue(workerPushes: true)
        #expect(permission.isOffering && permission.status == .notAsked)
        await permission.ask()
        #expect(!permission.isOffering && permission.status == .allowed && asked.with { $0 } == 1)
        await permission.offerIfDue(workerPushes: true)
        #expect(!permission.isOffering)
    }

    @Test func notNowIsKeptUntilTheNextPairing() async {
        let (permission, defaults) = permission(.notDetermined)
        await permission.offerIfDue(workerPushes: true)
        permission.decline()
        await permission.offerIfDue(workerPushes: true)
        #expect(!permission.isOffering)
        let center = PRHubAlertPermission.Center(status: { .notDetermined }, request: { false })
        let again = PRHubAlertPermission(center: center, defaults: defaults)
        await again.offerIfDue(workerPushes: true)
        #expect(!again.isOffering)
        again.forgetDecline()
        await again.offerIfDue(workerPushes: true)
        #expect(again.isOffering)
    }

    @Test func eachAnswerToTheOfferIsRecorded() async {
        let sink = AnalyticsTests.RecordingAnalytics()
        let (allowing, _) = permission(.notDetermined)
        allowing.usage = resources.usage(sink)
        await allowing.ask()
        let center = PRHubAlertPermission.Center(status: { .denied }, request: { false })
        let denying = PRHubAlertPermission(center: center, defaults: resources.defaults())
        denying.usage = allowing.usage
        await denying.ask()
        denying.decline()
        #expect(sink.events == [.alertsAnswered(.allowed), .alertsAnswered(.denied), .alertsAnswered(.notNow)])
    }

    @Test func aWorkerThatDoesNotPushOrAnAnsweredQuestionOffersNothing() async {
        let (quiet, _) = permission(.notDetermined)
        await quiet.offerIfDue(workerPushes: false)
        #expect(!quiet.isOffering)
        let (denied, _) = permission(.denied)
        await denied.offerIfDue(workerPushes: true)
        #expect(!denied.isOffering && denied.status == .denied)
    }
}
