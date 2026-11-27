#if DEBUG
    import Foundation
    import PRKit
    import Synchronization
    #if os(iOS)
        import UIKit
    #endif

    /// Debug builds only: the launch arguments the UI tests and the screenshot captures use to put PRHub on screen with no
    /// Worker. Tester Army's modes (e2e/e2e.config.ts) are the same ones.
    /// - `-PRHubFirstRun`: onboarding, as on a new phone, with a pairing that is always refused and a fake hosted Worker:
    ///   Sign in with GitHub signs in as `octocat` at once (`-PRHubSignInDenied`: GitHub says the person cancelled), and the
    ///   list is the samples. The ways in follow the build's flags; `-PRHubSelfHosted YES` (any flag, `PRHubBuild`) changes
    ///   one.
    /// - `-PRHubHosted`: signed in on that fake hosted Worker. With `-PRHubSignedOut` GitHub signed the person out; with
    ///   `-PRHubHostedEmpty` the list is empty; with `-PRHubSettings` it opens on
    ///   Settings. The App is installed on `octocat`, on two of acme's repos and, suspended, on initech; with
    ///   `-PRHubInstallations none` on no account, and with `-PRHubInstallations onReturn` on `octocat` alone until the
    ///   app leaves the foreground (as for GitHub), and on acme too when it comes back.
    /// - `-PRHubPaired`: the PRs and Settings over the sample PRs as if paired, every AI feature on. With `-PRHubSettings`
    ///   it opens on Settings; with `-PRHubLongDiff` For review starts with a PR whose one file is longer than the screen,
    ///   for the diff's bars; with `-PRHubLongLines` it starts with a PR of lines too long for any screen
    ///   (`PRHubLongLineSamples`); with `-PRHubCompactWidth` the PRs tab lays out as in a narrow Split View; with
    ///   `-PRHubSlowReview` a review takes 10 seconds to land, so a UI test still finds its toast after a navigation,
    ///   and its toast then stays, so the test reads what it says however slowly it looks;
    ///   with `-PRHubPendingAddRefused` a pending comment added on a line is refused, as GitHub refuses one on a line
    ///   outside the diff, so a UI test can show a failed one;
    ///   with `-PRHubHiddenLines` For review starts with a PR whose diff leaves lines out (`PRHubHiddenLineSamples`);
    ///   with `-PRHubFeedback` the Worker serves Feedback, over two sample chats that never leave the device
    ///   (`FeatureSamples.prHub`), with `-PRHubFeedbackPush <chat>` it opens as a tapped push of that feedback
    ///   chat does, and with `-PRHubFeedbackAsks` a third chat's agent has asked a question, so Feedback is badged.
    ///
    /// Each launch starts on empty storage of its own (`PRHubUITestResources`). `-prkit.diffFont face:size` sets one for
    /// the run. `-PRHubAppearance dark` (or `light`) sets the run's appearance whatever the Simulator's is: on CI's
    /// Simulator `XCUIDevice.shared.appearance` left everything light, so every "dark" picture came out light.
    public enum PRHubFixtureEnvironment {
        @MainActor public static func environment(
            usage: @MainActor (UserDefaults) -> UsageAnalytics, testFlightGroup: TestFlightGroup
        ) -> PRHubEnvironment? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let resources = PRHubUITestResources.current else {
                return nil
            }
            if arguments.contains("-PRHubFirstRun") {
                return fakeHosted(signedIn: false, arguments: arguments, usage: usage, resources: resources)
            }
            if arguments.contains("-PRHubHosted") {
                let environment = fakeHosted(signedIn: true, arguments: arguments, usage: usage, resources: resources)
                if arguments.contains("-PRHubSettings") {
                    environment.navigation.selectedTab = .settings
                }
                return environment
            }
            // `-PRHubPaired`, the one fixture mode left.
            let servesFeedback = arguments.contains("-PRHubFeedback")
            let features: Set<DeviceFeature> = [.askAI, .keyLines, .rewrite, .push]
            let environment = PRHubEnvironment.offline(
                config: DeviceConfig(
                    features: servesFeedback ? features.union([.feedback]) : features, login: PRSampleSet.prHubLogin
                ),
                samples: pairedSamples(arguments),
                feedbackSamples: servesFeedback ? (arguments.contains("-PRHubFeedbackAsks") ? .prHubAsking : .prHub) : nil,
                worker: URL(string: "https://pr-review.octocat.workers.dev")!,
                isSample: false, usage: usage(resources.defaults), testFlightGroup: testFlightGroup,
                storage: resources.storage(), build: .current, alertPermission: resources.alertPermission(),
                network: PRNetwork(isOnline: true)
            )
            resources.isolateAlerts(in: environment)
            askStatus(arguments, in: environment)
            if let chat = UserDefaults.standard.string(forKey: "PRHubFeedbackPush") {
                environment.openFeedbackChat(chat)
            }
            if arguments.contains("-PRHubSettings") {
                environment.navigation.selectedTab = .settings
            }
            return environment
        }

        /// `-PRHubAskState working|answered`: a live Ask AI chat on acme/web#412, as if its sheet had been closed.
        @MainActor private static func askStatus(_ arguments: [String], in environment: PRHubEnvironment) {
            let value = { (name: String) in
                arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            }
            let ref = PullRequestRef(repo: "acme/web", number: 412)
            switch value("-PRHubAskState") {
            case "working": environment.prs.showAskActivity(on: ref, answered: false)
            case "answered": environment.prs.showAskActivity(on: ref, answered: true)
            default: break
            }
        }

        private static func pairedSamples(_ arguments: [String]) -> PRSampleSet {
            var samples: PRSampleSet = arguments.contains("-PRHubLongDiff") ? .prHubLongDiff : .prHub
            if arguments.contains("-PRHubLongLines") {
                let bytes = UserDefaults.standard.integer(forKey: "PRHubLongLineBytes")
                samples = .prHubLongLines(bytes: bytes > 0 ? bytes : PRHubLongLineSamples.defaultBytes)
            }
            if arguments.contains("-PRHubHiddenLines") {
                samples = .prHubHiddenLines
            }
            if arguments.contains("-PRHubSlowReview") {
                samples.reviewDelay = .seconds(10)
                samples.reviewDwell = .seconds(3600)
            }
            if arguments.contains("-PRHubPendingAddRefused") {
                samples.refusesLinePendingAdds = "GitHub didn't take the comment. Its line may no longer be in the diff."
            }
            return samples
        }

        /// The hosted Worker's stand-in: sign-in, sign-out, Delete Account and the Anthropic key answer at once, and the
        /// config says what they did.
        @MainActor private static func fakeHosted(
            signedIn: Bool, arguments: [String], usage: @MainActor (UserDefaults) -> UsageAnalytics,
            resources: PRHubUITestResources
        ) -> PRHubEnvironment {
            let build = PRHubBuild.current
            let worker = build.hostedURL ?? URL(string: "https://prhub.example.workers.dev")!
            let endpoint = WorkerEndpoint(store: resources.endpointStore)
            if signedIn {
                try? endpoint.save(worker)
            }
            let defaults = resources.configurationDefaults
            let state = FakeAccount(arguments: arguments)
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
                removeAnthropicKey: { state.setKey(false) },
                setLinearKey: { _ in state.setLinearKey(true) },
                removeLinearKey: { state.setLinearKey(false) }
            )
            let connection = WorkerConnection(
                endpoint: endpoint,
                pairing: DevicePairing(
                    pair: { _, _ in throw PairingClient.Failure.server("pairing_code_invalid", 401) },
                    save: { _ in }
                ),
                fetchConfig: { _ in state.config }, forgetSecret: {}, defaults: defaults, build: build,
                usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults), hosted: hosted
            )
            let samples: PRSampleSet = arguments.contains("-PRHubHostedEmpty")
                ? PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true) : .prHub
            let environment = PRHubEnvironment(
                connection: connection, storage: resources.storage(sampleConfiguration: resources.sampleDefaults),
                alertPermission: resources.alertPermission(), samples: samples, usage: usage(resources.defaults),
                network: PRNetwork(isOnline: true)
            )
            resources.isolateAlerts(in: environment)
            return environment
        }
    }

    /// What the fake hosted Worker holds for its one person.
    private final class FakeAccount: Sendable {
        /// Where the PRHub App is installed for the person (`-PRHubInstallations`).
        enum Installations: Sendable {
            case some, none, onReturn

            init(_ argument: String?) {
                switch argument {
                case "none": self = .none
                case "onReturn": self = .onReturn
                default: self = .some
                }
            }
        }

        private struct State {
            var signedOut: Bool
            var linearKey = false
            var anthropicKey: Bool
            var installations: Installations
            var hasLeft = false
        }

        private let state: Mutex<State>

        /// `-PRHubSignedOut` and `-PRHubInstallations`; the Anthropic key starts unset.
        init(arguments: [String]) {
            state = Mutex(State(
                signedOut: arguments.contains("-PRHubSignedOut"), anthropicKey: false,
                installations: Installations(UserDefaults.standard.string(forKey: "PRHubInstallations"))
            ))
            watchForGitHub()
        }

        /// The app leaving the foreground stands in for the person going to GitHub to install the App.
        private func watchForGitHub() {
            #if os(iOS)
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
                ) { [self] _ in state.withLock { $0.hasLeft = true } }
            #endif
        }

        private static let own = GitHubInstallation(
            account: PRSampleSet.prHubLogin, accountType: .user, installationID: 101, repositorySelection: .all
        )
        private static let acme = GitHubInstallation(
            account: "acme", accountType: .organization, installationID: 202, repositorySelection: .selected, repoCount: 2
        )
        private static let initech = GitHubInstallation(
            account: "initech", accountType: .organization, installationID: 303, repositorySelection: .all, suspended: true
        )

        private static func installations(_ state: State) -> [GitHubInstallation] {
            switch state.installations {
            case .some: [own, acme, initech]
            case .none: []
            case .onReturn: state.hasLeft ? [own, acme] : [own]
            }
        }

        var config: DeviceConfig {
            let now = state.withLock { $0 }
            let ai: Set<DeviceFeature> = now.anthropicKey ? [.keyLines, .rewrite, .askAI] : []
            return DeviceConfig(
                features: ai.union([.push, .webhooks]), login: PRSampleSet.prHubLogin, hosted: true,
                account: DeviceConfig.Account(
                    state: now.signedOut ? .signedOut : .signedIn, login: PRSampleSet.prHubLogin, userId: "4242",
                    anthropicKey: now.anthropicKey, reason: now.signedOut ? "revoked" : nil, linearKey: now.linearKey
                ),
                installations: now.signedOut ? nil : Self.installations(now)
            )
        }

        func signIn() {
            state.withLock { $0.signedOut = false }
        }

        func setLinearKey(_ isSet: Bool) {
            state.withLock { $0.linearKey = isSet }
        }

        func setKey(_ isSet: Bool) {
            state.withLock { $0.anthropicKey = isSet }
        }
    }

    extension PRSampleSet {
        /// The samples, with two more PRs first on For review: one file longer than any phone's screen, and three such files.
        static let prHubLongDiff = PRSampleSet(
            samples: [longDiff, longFiles] + prHub.samples, mergedReviewed: [], mergedMine: [], answersOnPhone: true
        )

        private static let longDiffMembers = (1 ... 30).map { "member_\($0)" }

        private static let longDiff = PRHubSample(
            repo: "acme/infra", number: 31, title: "Give the deploy team access to staging", list: "review",
            author: "mona", checks: "passing", review: "required", merge: "clean",
            body: "Adds an access membership for each of the deploy team.",
            diff: """
            diff --git a/zero-trust/cloudflare/access/deploy_memberships.tf b/zero-trust/cloudflare/access/deploy_memberships.tf
            --- /dev/null
            +++ b/zero-trust/cloudflare/access/deploy_memberships.tf
            @@ -0,0 +1,\(longDiffMembers.count * 5) @@

            """ + longDiffMembers.map { name in
                "+resource \"access_membership\" \"\(name)\" {\n+  group  = \"deploy\"\n+  member = \"\(name)\"\n+}\n+\n"
            }.joined(),
            keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil
        ).sample

        private static func longFile(_ path: String) -> String {
            """
            diff --git a/\(path) b/\(path)
            --- /dev/null
            +++ b/\(path)
            @@ -0,0 +1,\(longDiffMembers.count * 5) @@

            """ + longDiffMembers.map { name in
                "+resource \"access_membership\" \"\(name)\" {\n+  group  = \"deploy\"\n+  member = \"\(name)\"\n+}\n+\n"
            }.joined()
        }

        /// Three files, each longer than the screen: folding one from its pinned header, read from inside it.
        private static let longFiles = PRHubSample(
            repo: "acme/infra", number: 32, title: "Give every team access to staging", list: "review",
            author: "mona", checks: "passing", review: "required", merge: "clean",
            body: "Adds an access membership for each of three teams.",
            diff: ["deploy", "data", "support"].map { longFile("zero-trust/\($0)_memberships.tf") }.joined(),
            keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil
        ).sample
    }
#endif
