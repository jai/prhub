#if DEBUG
    import Foundation
    import PRKit
    import Synchronization
    #if os(iOS)
        import UIKit
    #endif

    /// Debug builds only: the launch arguments the UI tests use to put PRHub on screen with no Worker.
    /// - `-PRHubFirstRun`: onboarding, as on a new phone, with a pairing that is always refused and a fake hosted Worker:
    ///   Sign in with GitHub signs in as `octocat` at once (`-PRHubSignInDenied`: GitHub says the person cancelled), and the
    ///   list is the samples. The ways in follow the build's flags; `-PRHubSelfHosted YES` (any flag, `PRHubBuild`) changes
    ///   one.
    /// - `-PRHubHosted`: signed in on that fake hosted Worker. With `-PRHubSignedOut` GitHub signed the person out; with
    ///   `-PRHubHostedEmpty` the list is empty; with `-PRHubAnthropicKey` a key is set; with `-PRHubSettings` it opens on
    ///   Settings; with `-PRHubNoLinear` the PRs come as the Worker sends them before Linear is connected, so a PR's
    ///   ticket asks to connect it. The App is installed on `octocat`, on two of acme's repos and, suspended, on initech; with
    ///   `-PRHubInstallations none` on no account, and with `-PRHubInstallations onReturn` on `octocat` alone until the
    ///   app leaves the foreground (as for GitHub), and on acme too when it comes back.
    /// - `-PRHubPaired`: the PRs and Settings over the sample PRs as if paired, every AI feature on. With `-PRHubAskWorking`
    ///   Ask has a question the agent is still on; with `-PRHubAskAnswered` the agent's long answer to it. With `-PRHubNoAI` the
    ///   Worker has no model key; with `-PRHubSettings` it opens on Settings; with `-PRHubLongDiff` For review starts with a
    ///   PR whose one file is longer than the screen, for the diff's bars; with `-PRHubOpen <link>` it opens that PR as a
    ///   link would (`…/pull/N/files` on its diff); with `-PRHubCompactWidth` the PRs tab lays out as in a narrow Split View;
    ///   with `-PRHubRefuseFirstReview` the first review sent is refused, so its toast shows Retry, and each review takes
    ///   3 seconds to answer. With `-PRHubOffline` the device counts as offline, under the offline banner. With
    ///   `-PRHubNewerBuild <n>` it checks for updates, and the config's `app_latest` names this
    ///   build's version with a build number `n` higher (0: this build).
    ///
    /// Each launch starts on empty storage of its own (`PRHubUITestResources`); `-PRHubKeepState` keeps the last
    /// launch's. `-prkit.diffFont face:size`
    /// sets one for the run. `-PRHubAppearance dark` (or `light`) sets the run's appearance whatever the Simulator's is: on
    /// CI's Simulator `XCUIDevice.shared.appearance` left everything light, so every "dark" picture came out light.
    public enum PRHubScreenshotEnvironment {
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
            if arguments.contains("-PRHubStubWorker") {
                return PRHubStubWorker.environment(arguments, resources: resources)
            }
            if arguments.contains("-PRHubOutboxCheck") {
                return PRHubOutboxCheck.environment(resources)
            }
            if arguments.contains("-PRHubHosted") {
                let environment = fakeHosted(signedIn: true, arguments: arguments, usage: usage, resources: resources)
                if arguments.contains("-PRHubSettings") {
                    environment.navigation.selectedTab = .settings
                }
                return environment
            }
            // `-PRHubPaired`, the one fixture mode left.
            let features: Set<DeviceFeature> = arguments.contains("-PRHubNoAI")
                ? [.push] : [.askAI, .keyLines, .rewrite, .push]
            let samples = pairedSamples(arguments)
            let newer = UserDefaults.standard.string(forKey: "PRHubNewerBuild").flatMap { Int($0) }
            let environment = PRHubEnvironment.offline(
                config: DeviceConfig(features: features, login: PRSampleSet.prHubLogin, appLatest: Self.appLatest(newer)),
                samples: samples,
                worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "screenshots-paired",
                isSample: false, usage: usage(resources.defaults), checksUpdates: newer != nil,
                testFlightGroup: testFlightGroup,
                listDefaults: resources.defaults, configurationDefaults: resources.configurationDefaults,
                storageDirectory: resources.directory, network: PRNetwork(isOnline: true),
                alertPermission: resources.alertPermission()
            )
            resources.isolateAlerts(in: environment)
            if arguments.contains("-PRHubSettings") {
                environment.navigation.selectedTab = .settings
            }
            // On the Mac this opens the Feedback window; the phone has the tab only where the Worker serves it.
            if arguments.contains("-PRHubFeedback") {
                environment.navigation.selectedTab = .feedback
            }
            if let index = arguments.firstIndex(of: "-PRHubOpen"), arguments.indices.contains(index + 1) {
                environment.prs.open(text: arguments[index + 1])
            }
            if arguments.contains("-PRHubOffline") {
                environment.prs.network.holdOffline()
            }
            return environment
        }

        private static func pairedSamples(_ arguments: [String]) -> PRSampleSet {
            var samples: PRSampleSet = arguments.contains("-PRHubLongDiff") ? .prHubLongDiff : .prHub
            samples.askChat = askChat(arguments)
            if arguments.contains("-PRHubRefuseFirstReview") {
                samples.refusesFirstReview = "GitHub didn't answer in time."
                // Long enough for a loaded test Mac, and a recording, to see each step.
                samples.reviewDelay = .seconds(3)
            }
            // The list under its "Not up to date" line.
            if arguments.contains("-PRHubNotUpToDate") {
                samples.notUpToDate = "1 of 125 PRs could not be downloaded and show their last copy. Refresh to try again."
            }
            return samples
        }

        /// `-PRHubAskWorking`: a question the agent is on. `-PRHubAskAnswered`: its long answer, in Markdown with code.
        static func askChat(_ arguments: [String]) -> PRAskChat? {
            let question = PRAskChat.Message(id: "question-1", role: "you", text: "Is this change tested?", anchor: nil)
            if arguments.contains("-PRHubAskWorking") {
                return PRAskChat(messages: [question], isWorking: true, activity: nil, problem: nil, costCents: nil)
            }
            guard arguments.contains("-PRHubAskAnswered") else {
                return nil
            }
            let answer = PRAskChat.Message(
                id: "answer-1", role: "agent",
                text: """
                Partly. The retry path is covered, but two things are not:

                - **Idempotency:** `retryPayment` sends the same payment key on every attempt, and \
                `PaymentServiceTests.testRetryReusesTheKey` checks it whether or not the flag is set.
                - **Reachability:** at this head, `recordOtpVerified` has no caller in `functions/src` outside tests, \
                so the recovery screen can never reach it. Either call it from `verifyOtp` or drop it from this PR.
                """,
                anchor: nil
            )
            return PRAskChat(messages: [question, answer], isWorking: false, activity: nil, problem: nil, costCents: nil)
        }

        /// `-PRHubNewerBuild <n>`'s: this build's version, its build number plus `n`, for both groups.
        private static func appLatest(_ newer: Int?) -> DeviceConfig.AppLatest? {
            guard let newer else {
                return nil
            }
            let running = AppBuild.running
            let build = AppBuild(version: running.version, build: String((Int(running.build) ?? 0) + newer))
            return DeviceConfig.AppLatest(internal: build, public: build)
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
            if signedIn, resources.isFresh {
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
            var samples: PRSampleSet = arguments.contains("-PRHubHostedEmpty")
                ? PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true) : .prHub
            if arguments.contains("-PRHubNoLinear") {
                samples = samples.withoutLinear
            }
            let environment = PRHubEnvironment(
                connection: connection, samples: samples, alertPermission: resources.alertPermission(),
                usage: usage(resources.defaults), defaults: resources.defaults, sampleDefaults: resources.sampleDefaults,
                storageDirectory: resources.directory, network: PRNetwork(isOnline: true)
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

        /// `-PRHubSignedOut`, `-PRHubAnthropicKey` and `-PRHubInstallations`.
        init(arguments: [String]) {
            state = Mutex(State(
                signedOut: arguments.contains("-PRHubSignedOut"), anthropicKey: arguments.contains("-PRHubAnthropicKey"),
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
        /// As the hosted Worker answers an account without Linear (docs/api.md, "Rows and details"): a PR's page has
        /// the keys its title names, each the key alone, and no row has a ticket.
        var withoutLinear: PRSampleSet {
            PRSampleSet(
                samples: samples.map { sample in
                    var row = sample.row
                    row.ticket = nil
                    row.tickets = []
                    return Sample(
                        row: row, detail: Self.unresolved(sample.detail, title: row.title), diff: sample.diff,
                        keyLines: sample.keyLines
                    )
                },
                mergedReviewed: mergedReviewed, mergedMine: mergedMine, answersOnPhone: answersOnPhone
            )
        }

        private static func unresolved(_ detail: String, title: String) -> String {
            guard var object = (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any],
                  let tickets = object["tickets"] as? [[String: Any]]
            else {
                return detail
            }
            object["tickets"] = tickets.compactMap { $0["key"] as? String }.filter { title.contains("[\($0)]") }
                .map { ["key": $0, "found": NSNull()] }
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
                ?? detail
        }

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
