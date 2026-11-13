import Foundation
import Testing
@testable import PRHub

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

    @Test func buildsCompareByVersionThenBuildNumber() {
        #expect(AppBuild(version: "1.0", build: "201").isNewer(than: Self.running))
        #expect(AppBuild(version: "1.10", build: "1").isNewer(than: AppBuild(version: "1.9", build: "300")))
        #expect(!AppBuild(version: "1.0", build: "200").isNewer(than: Self.running))
        #expect(!AppBuild(version: "1.0", build: "99").isNewer(than: Self.running))
        #expect(!AppBuild(version: "0.9", build: "900").isNewer(than: Self.running))
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

    @Test func aGroupThisBuildCannotReadIsLeftOut() throws {
        let json = #"{"features":{},"app_latest":{"internal":{"version":"1.0"},"#
            + #""public":{"version":"1.0","build":"7"}}}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
        #expect(config.appLatest?.build(for: .internal) == nil)
        #expect(config.appLatest?.build(for: .public) == AppBuild(version: "1.0", build: "7"))
    }
}
