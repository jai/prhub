import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

/// Update available (`PRHubUpdate`): a newer build for this build's TestFlight group, at most hourly, and Later.
@MainActor
struct PRHubUpdateTests {
    private let resources = IntegrationResources()
    private static let running = AppBuild(version: "1.0", build: "200")

    private static func config(
        internal internalBuild: String? = nil, public publicBuild: String? = nil
    ) -> DeviceConfig {
        DeviceConfig(features: [], appLatest: DeviceConfig.AppLatest(
            internal: internalBuild.map { AppBuild(version: "1.0", build: $0) },
            public: publicBuild.map { AppBuild(version: "1.0", build: $0) }
        ))
    }

    private func makeUpdate(
        group: TestFlightGroup = .public, clock: Shared<Date> = Shared(Date(timeIntervalSince1970: 1000))
    ) -> PRHubUpdate {
        PRHubUpdate(
            running: Self.running, group: group, defaults: resources.defaults(),
            isEnabled: true, usage: resources.usage(), now: { clock.with { $0 } }
        )
    }

    @Test func eachBuildComparesWithItsOwnGroup() {
        let internalBuild = makeUpdate(group: .internal)
        internalBuild.check(Self.config(internal: "205", public: "200"))
        #expect(internalBuild.offered?.build == "205")

        let release = makeUpdate(group: .public)
        release.check(Self.config(internal: "205", public: "200"))
        #expect(release.offered == nil)
    }

    @Test func laterSkipsThatBuildAndANewerOneIsOfferedAgain() {
        let clock = Shared(Date(timeIntervalSince1970: 1000))
        let update = makeUpdate(clock: clock)
        update.check(Self.config(public: "201"))
        #expect(update.offered == AppBuild(version: "1.0", build: "201"))
        update.later()
        #expect(update.offered == nil)

        clock.with { $0 += PRHubUpdate.interval }
        update.check(Self.config(public: "201"))
        #expect(update.offered == nil)

        clock.with { $0 += PRHubUpdate.interval }
        update.check(Self.config(public: "202"))
        #expect(update.offered?.build == "202")
    }

    @Test func theOfferAndTheAnswerAreReported() {
        let sink = AnalyticsTests.RecordingAnalytics()
        let update = PRHubUpdate(
            running: Self.running, defaults: resources.defaults(),
            isEnabled: true, usage: resources.usage(sink)
        )
        update.check(Self.config(public: "201"))
        update.later()
        update.opened(accepted: true)
        update.opened(accepted: false)
        #expect(sink.events == [.updateOffered(.public, build: 201), .updateAnswered(.later), .updateOpenFailed])
    }

    @Test func checkedAtMostHourly() {
        let clock = Shared(Date(timeIntervalSince1970: 1000))
        let update = makeUpdate(clock: clock)
        update.check(Self.config(public: "200"))
        clock.with { $0 += PRHubUpdate.interval - 60 }
        update.check(Self.config(public: "201"))
        #expect(update.offered == nil)
        clock.with { $0 += 60 }
        update.check(Self.config(public: "201"))
        #expect(update.offered?.build == "201")
    }

    @Test func nothingWithoutAConfigInADebugBuildOrWhenTheWorkerDoesNotSay() {
        let update = makeUpdate()
        update.check(nil)
        update.check(DeviceConfig(features: []))
        #expect(update.offered == nil)
        let debug = PRHubUpdate(running: Self.running, defaults: resources.defaults(), isEnabled: false, usage: resources.usage())
        debug.check(Self.config(public: "300"))
        #expect(debug.offered == nil)
    }
}
