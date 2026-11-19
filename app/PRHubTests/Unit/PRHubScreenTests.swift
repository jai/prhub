import DurableNetworking
import Foundation
@testable import PRHubCore
@testable import PRKit
import PRKitTestSupport
import Testing

@MainActor
struct PRHubScreenTests {
    private let resources = UnitResources()
    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)

    @Test func aHostedWorkerWithoutAKeyPointsKeyLinesAtSettings() {
        let selfHosted = PRHubPRHost.configuration(DeviceConfig(features: [.push]))
        #expect(!selfHosted.isOn(.keyLines) && selfHosted.keyLinesHint == nil)
        let hosted = PRHubPRHost.configuration(DeviceConfig(features: [.push], hosted: true))
        #expect(!hosted.isOn(.keyLines) && hosted.keyLinesHint == PRHubPRHost.anthropicKeyHint)
    }

    @Test func connectingLinearOpensLinearInSettings() {
        let environment = resources.environment()
        environment.navigation.showLinearSettings()
        #expect(environment.navigation.selectedTab == .settings && environment.navigation.settingsSection == .linear)
    }

    @Test func aRefusedSignInFromTheSamplesKeepsThemAndSaysWhy() async throws {
        let worker = try #require(URL(string: "https://prhub.example.workers.dev"))
        let settings = resources.defaults()
        let connection = try WorkerConnection(
            endpoint: resources.endpoint(),
            pairing: DevicePairing(pair: { _, _ in throw PairingClient.Failure.transport }, save: { _ in }),
            fetchConfig: { _ in DeviceConfig(features: []) }, forgetSecret: {}, defaults: settings,
            build: PRHubBuild(hostedURL: worker, signInWithGitHub: true, selfHosted: false, samples: true),
            usage: resources.usage(),
            hosted: WorkerConnection.Hosted(
                worker: worker, signIn: { throw SignInError.denied }, saveSecret: { _ in }, signOut: {},
                deleteAccount: {}, setAnthropicKey: { _ in }, removeAnthropicKey: {}
            )
        )
        let environment = PRHubEnvironment(
            connection: connection, storage: resources.storage(settings: settings),
            alertPermission: resources.alertPermission(defaults: settings), usage: resources.usage(),
            network: PRNetwork(isOnline: true)
        )
        environment.startSample()
        let sample = try #require(environment.sample)
        _ = try await sample.prs.model.write(.comment(body: "Before signing in"), to: Self.checkout)

        await environment.leaveSample()
        #expect(environment.sample === sample, "still in the samples")
        #expect(connection.signInProblem != nil, "GitHub's refusal is said under the button")
        let row = try #require(sample.prs.model.rows.first { $0.number == Self.checkout.number })
        #expect(sample.prs.model.session(for: row).content?.detail.comments.nodes.last?.body == "Before signing in")
    }
}
