import Foundation
@testable import PRHubCore
import PRHubTestSupport
import Testing

/// Update available (`PRHubUpdate`): a newer build for this build's TestFlight group, at most hourly, and Later.
@MainActor
struct PRHubUpdateTests {
    private static let running = AppBuild(version: "1.0", build: "200")

    private static func config(
        internal internalBuild: String? = nil, public publicBuild: String? = nil
    ) -> DeviceConfig {
        DeviceConfig(features: [], appLatest: DeviceConfig.AppLatest(
            internal: internalBuild.map { AppBuild(version: "1.0", build: $0) },
            public: publicBuild.map { AppBuild(version: "1.0", build: $0) }
        ))
    }

    private static func update(
        group: TestFlightGroup = .public, clock: Shared<Date> = Shared(.now)
    ) -> PRHubUpdate {
        PRHubUpdate(
            running: running, group: group, defaults: UserDefaults(suiteName: "prhub-update-\(UUID().uuidString)")!,
            isEnabled: true, now: { clock.with { $0 } }
        )
    }

    @Test func eachBuildComparesWithItsOwnGroup() {
        let internalBuild = Self.update(group: .internal)
        internalBuild.check(Self.config(internal: "205", public: "200"))
        #expect(internalBuild.offered?.build == "205")

        let release = Self.update(group: .public)
        release.check(Self.config(internal: "205", public: "200"))
        #expect(release.offered == nil)
    }

    @Test func laterSkipsThatBuildAndANewerOneIsOfferedAgain() {
        let clock = Shared(Date.now)
        let update = Self.update(clock: clock)
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

    @Test func theOfferAndTheAnswerAreReported() throws {
        let sink = AnalyticsTests.RecordingAnalytics()
        let update = try PRHubUpdate(
            running: Self.running, defaults: #require(UserDefaults(suiteName: "prhub-update-\(UUID().uuidString)")),
            isEnabled: true, usage: AnalyticsTests.usage(sink)
        )
        update.check(Self.config(public: "201"))
        update.later()
        #expect(sink.events == [.updateOffered(.public, build: 201), .updateAnswered(.later)])
    }

    @Test func checkedAtMostHourly() {
        let clock = Shared(Date.now)
        let update = Self.update(clock: clock)
        update.check(Self.config(public: "200"))
        clock.with { $0 += PRHubUpdate.interval - 60 }
        update.check(Self.config(public: "201"))
        #expect(update.offered == nil)
        clock.with { $0 += 60 }
        update.check(Self.config(public: "201"))
        #expect(update.offered?.build == "201")
    }

    @Test func nothingWithoutAConfigInADebugBuildOrWhenTheWorkerDoesNotSay() {
        let update = Self.update()
        update.check(nil)
        update.check(DeviceConfig(features: []))
        #expect(update.offered == nil)
        let debug = PRHubUpdate(running: Self.running, isEnabled: false)
        debug.check(Self.config(public: "300"))
        #expect(debug.offered == nil)
    }
}
