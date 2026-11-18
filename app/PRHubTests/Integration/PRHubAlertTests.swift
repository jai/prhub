import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing
import UserNotifications

/// A tapped pr-worker alert opens its PR (docs/api.md, "Alerts"), and the one offer to turn alerts on.
@MainActor
struct PRHubAlertTests {
    private static let ref = PullRequestRef(repo: "acme/app", number: 7)

    @Test func anAlertOpensNothingDuringTheSamples() {
        let environment = PRHubEnvironment.sample()
        environment.openAlert(Self.ref)
        #expect(environment.navigation.selectedTab == .prs)
    }

    @Test func anAlertThatOpensNothingSaysWhy() {
        let sink = AnalyticsTests.RecordingAnalytics()
        let environment = PRHubEnvironment(
            connection: PRHubEnvironment.sample().connection, usage: AnalyticsTests.usage(sink)
        )
        environment.startSample()
        environment.openAlert(Self.ref)
        #expect(sink.events == [.onboardingPathChosen(.samples), .alertIgnored(.samples)])
    }

    // MARK: - The offer to turn alerts on

    private static func permission(
        _ status: UNAuthorizationStatus, asked: Shared<Int> = Shared(0)
    ) -> (PRHubAlertPermission, UserDefaults) {
        let defaults = UserDefaults(suiteName: "prhub-alerts-\(UUID().uuidString)")!
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
        let (permission, _) = Self.permission(.notDetermined, asked: asked)
        await permission.offerIfDue(workerPushes: true)
        #expect(permission.isOffering && permission.status == .notAsked)
        await permission.ask()
        #expect(!permission.isOffering && permission.status == .allowed && asked.with { $0 } == 1)
        await permission.offerIfDue(workerPushes: true)
        #expect(!permission.isOffering)
    }

    @Test func notNowIsKeptUntilTheNextPairing() async {
        let (permission, defaults) = Self.permission(.notDetermined)
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
        let (allowing, _) = Self.permission(.notDetermined)
        allowing.usage = AnalyticsTests.usage(sink)
        await allowing.ask()
        let center = PRHubAlertPermission.Center(status: { .denied }, request: { false })
        let denying = PRHubAlertPermission(center: center, defaults: AnalyticsTests.defaults())
        denying.usage = allowing.usage
        await denying.ask()
        denying.decline()
        #expect(sink.events == [.alertsAnswered(.allowed), .alertsAnswered(.denied), .alertsAnswered(.notNow)])
    }

    @Test func aWorkerThatDoesNotPushOrAnAnsweredQuestionOffersNothing() async {
        let (quiet, _) = Self.permission(.notDetermined)
        await quiet.offerIfDue(workerPushes: false)
        #expect(!quiet.isOffering)
        let (denied, _) = Self.permission(.denied)
        await denied.offerIfDue(workerPushes: true)
        #expect(!denied.isOffering && denied.status == .denied)
    }
}
