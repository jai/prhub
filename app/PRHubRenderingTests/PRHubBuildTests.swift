import Foundation
@testable import PRHubCore
import Testing

struct PRHubBuildTests {
    @Test func theAppsBuildSignsInAndHidesSelfHosting() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(Bundle.main.bundleIdentifier == "com.jaigovindani.prreview")
        let build = PRHubBuild(info: info)
        #expect(build.signInWithGitHub && build.samples && !build.selfHosted)
        #expect(build.hostedURL?.scheme == "https")
    }
}
