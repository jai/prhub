#if DEBUG
import Foundation
import PRKit
import SwiftUI
import Synchronization

/// Debug builds only: the launch arguments the UI tests use to put PRHub on screen with no Worker.
/// - `-PRHubFirstRun`: onboarding, as on a new phone, with a pairing that is always refused and a fake hosted Worker:
///   Sign in with GitHub signs in as `octocat` at once (`-PRHubSignInDenied`: GitHub says the person cancelled), and the
///   list is the samples. The ways in follow the build's flags; `-PRHubSelfHosted YES` (any flag, `PRHubBuild`) changes
///   one.
/// - `-PRHubHosted`: signed in on that fake hosted Worker. With `-PRHubSignedOut` GitHub signed the person out; with
///   `-PRHubHostedEmpty` the list is empty; with `-PRHubAnthropicKey` a key is set; with `-PRHubSettings` it opens on
///   Settings.
/// - `-PRHubPaired`: the PRs and Settings over the sample PRs as if paired, every AI feature on. With `-PRHubNoAI` the
///   Worker has no model key; with `-PRHubSettings` it opens on Settings; with `-PRHubLongDiff` For review starts with a
///   PR whose one file is longer than the screen, for the diff's bars; with `-PRHubOpen <link>` it opens that PR as a
///   link would (`…/pull/N/files` on its diff); with `-PRHubCompactWidth` the PRs tab lays out as in a narrow Split View.
///
/// Every one starts at the default diff font, whatever an earlier run chose in Settings; `-prkit.diffFont face:size`
/// sets one for the run. `-PRHubAppearance dark` (or `light`) sets the run's appearance whatever the Simulator's is: on
/// CI's Simulator `XCUIDevice.shared.appearance` left everything light, so every "dark" picture came out light.
enum PRHubScreenshots {
    static let appearanceKey = "PRHubAppearance"

    /// The appearance `-PRHubAppearance` asks for; nil follows the system.
    static func colorScheme(_ defaults: UserDefaults = .standard) -> ColorScheme? {
        switch defaults.string(forKey: appearanceKey) {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    @MainActor static func environment() -> PRHubEnvironment? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("-PRHub") }) {
            UserDefaults.standard.removeObject(forKey: DiffFont.storageKey)
        }
        if arguments.contains("-PRHubFirstRun") {
            return firstRun()
        }
        if arguments.contains("-PRHubHosted") {
            let environment = hosted(arguments)
            if arguments.contains("-PRHubSettings") {
                environment.navigation.selectedTab = .settings
            }
            return environment
        }
        guard arguments.contains("-PRHubPaired") else {
            return nil
        }
        let features: Set<DeviceFeature> = arguments.contains("-PRHubNoAI")
            ? [.push] : [.askAI, .keyLines, .rewrite, .push]
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: features, login: PRSampleSet.prHubLogin),
            samples: arguments.contains("-PRHubLongDiff") ? .prHubLongDiff : .prHub,
            worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "screenshots-paired",
            isSample: false
        )
        if arguments.contains("-PRHubSettings") {
            environment.navigation.selectedTab = .settings
        }
        if let index = arguments.firstIndex(of: "-PRHubOpen"), arguments.indices.contains(index + 1) {
            environment.prs.open(text: arguments[index + 1])
        }
        return environment
    }

    /// `-PRHubCompactWidth`: the PRs tab as a narrow Split View or Slide Over has it, on any screen.
    static var forcesCompactWidth: Bool {
        ProcessInfo.processInfo.arguments.contains("-PRHubCompactWidth")
    }

    @MainActor private static func firstRun() -> PRHubEnvironment {
        fakeHosted(signedIn: false, arguments: ProcessInfo.processInfo.arguments)
    }

    @MainActor private static func hosted(_ arguments: [String]) -> PRHubEnvironment {
        fakeHosted(signedIn: true, arguments: arguments)
    }

    /// The hosted Worker's stand-in: sign-in, sign-out, Delete Account and the Anthropic key answer at once, and the
    /// config says what they did.
    @MainActor private static func fakeHosted(signedIn: Bool, arguments: [String]) -> PRHubEnvironment {
        let build = PRHubBuild.current
        let worker = build.hostedURL ?? URL(string: "https://prhub.example.workers.dev")!
        let store = WorkerURLStore(service: AppIdentity.bundleID + ".screenshots-first-run", account: "url")
        let endpoint = WorkerEndpoint(store: store)
        try? endpoint.clear()
        if signedIn {
            try? endpoint.save(worker)
        }
        let defaults = UserDefaults(suiteName: "screenshots-first-run") ?? .standard
        defaults.removePersistentDomain(forName: "screenshots-first-run")
        let state = FakeAccount(
            signedOut: arguments.contains("-PRHubSignedOut"), anthropicKey: arguments.contains("-PRHubAnthropicKey")
        )
        if signedIn {
            defaults.set(try? JSONEncoder().encode(state.config), forKey: WorkerConnection.configKey)
        }
        let denied = arguments.contains("-PRHubSignInDenied")
        let hosted = WorkerConnection.Hosted(
            worker: worker,
            signIn: {
                try await HostedSignIn(worker: worker, authenticate: { start, host in
                    let appState = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "state" }?.value ?? ""
                    try await Task.sleep(for: .milliseconds(600))
                    let answer = denied ? "error=access_denied&state=\(appState)" : "code=one-time&state=\(appState)"
                    return URL(string: "https://\(host)\(SignInAttempt.callbackPath)?\(answer)")!
                }, finish: { _, _ in
                    SignInResult(secret: "4242.screenshots", login: PRSampleSet.prHubLogin, userId: "4242")
                }).run()
            },
            saveSecret: { _ in state.signIn() },
            signOut: {},
            deleteAccount: { try await Task.sleep(for: .milliseconds(600)) },
            setAnthropicKey: { _ in
                try await Task.sleep(for: .milliseconds(600))
                state.setKey(true)
            },
            removeAnthropicKey: { state.setKey(false) }
        )
        let connection = WorkerConnection(
            endpoint: endpoint,
            pairing: DevicePairing(
                pair: { _, _ in throw PairingClient.Failure.server("pairing_code_invalid", 401) },
                save: { _ in }
            ),
            fetchConfig: { state.config }, forgetSecret: {}, defaults: defaults, build: build, hosted: hosted
        )
        let samples: PRSampleSet = arguments.contains("-PRHubHostedEmpty")
            ? PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true) : .prHub
        return PRHubEnvironment(connection: connection, samples: samples)
    }
}

/// What the fake hosted Worker holds for its one person.
private final class FakeAccount: Sendable {
    private struct State {
        var signedOut: Bool
        var anthropicKey: Bool
    }

    private let state: Mutex<State>

    init(signedOut: Bool, anthropicKey: Bool) {
        state = Mutex(State(signedOut: signedOut, anthropicKey: anthropicKey))
    }

    var config: DeviceConfig {
        let now = state.withLock { $0 }
        let ai: Set<DeviceFeature> = now.anthropicKey ? [.keyLines, .rewrite, .askAI] : []
        return DeviceConfig(
            features: ai.union([.push, .webhooks]), login: PRSampleSet.prHubLogin, hosted: true,
            account: DeviceConfig.Account(
                state: now.signedOut ? .signedOut : .signedIn, login: PRSampleSet.prHubLogin, userId: "4242",
                anthropicKey: now.anthropicKey, reason: now.signedOut ? "revoked" : nil
            )
        )
    }

    func signIn() {
        state.withLock { $0.signedOut = false }
    }

    func setKey(_ isSet: Bool) {
        state.withLock { $0.anthropicKey = isSet }
    }
}

extension PRSampleSet {
    /// The samples, with one more PR first on For review: one file, longer than any phone's screen.
    static let prHubLongDiff = PRSampleSet(
        samples: [longDiff] + prHub.samples, mergedReviewed: [], mergedMine: [], answersOnPhone: true
    )

    private static let longDiffMembers = (1...30).map { "member_\($0)" }

    private static let longDiff = PRHubSample(
        repo: "acme/infra", number: 31, title: "Give the deploy team access to staging", list: "review",
        author: "mona", checks: "passing", review: "required", merge: "clean",
        body: "Adds an access membership for each of the deploy team.",
        diff: """
        diff --git a/zero-trust/access_memberships.tf b/zero-trust/access_memberships.tf
        --- /dev/null
        +++ b/zero-trust/access_memberships.tf
        @@ -0,0 +1,\(longDiffMembers.count * 5) @@

        """ + longDiffMembers.map { name in
            "+resource \"access_membership\" \"\(name)\" {\n+  group  = \"deploy\"\n+  member = \"\(name)\"\n+}\n+\n"
        }.joined(),
        keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil
    ).sample
}
#endif
