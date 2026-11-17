import Foundation
@testable import PRHubCore
import Testing

struct BuildVersionTests {
    private static let running = AppBuild(version: "1.0", build: "200")

    @Test func buildsCompareByVersionThenBuildNumber() {
        #expect(AppBuild(version: "1.0", build: "201").isNewer(than: Self.running))
        #expect(AppBuild(version: "1.10", build: "1").isNewer(than: AppBuild(version: "1.9", build: "300")))
        #expect(!AppBuild(version: "1.0", build: "200").isNewer(than: Self.running))
        #expect(!AppBuild(version: "1.0", build: "99").isNewer(than: Self.running))
        #expect(!AppBuild(version: "0.9", build: "900").isNewer(than: Self.running))
    }

    @Test func aGroupThisBuildCannotReadIsLeftOut() throws {
        let json = #"{"features":{},"app_latest":{"internal":{"version":"1.0"},"#
            + #""public":{"version":"1.0","build":"7"}}}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
        #expect(config.appLatest?.build(for: .internal) == nil)
        #expect(config.appLatest?.build(for: .public) == AppBuild(version: "1.0", build: "7"))
    }
}
