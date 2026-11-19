import DurableNetworking
import Foundation
@testable import PRHubCore
@testable import PRKit
import PRKitTestSupport
import Testing

/// What PRHub's screens decide over the sample PRs, without drawing them: the PR's page, its panel, Ask's ticks, the
/// list's lines and empty states, a ticket that asks for Linear, and leaving the samples. Each was a UI test's
/// assertion; the UI tests keep what only a screen shows (layout, gestures, the system's own screens).
@MainActor
struct PRHubScreenTests {
    private let resources = UnitResources()
    private static let checkout = PullRequestRef(repo: "acme/web", number: 412)
    private static let rateLimit = PullRequestRef(repo: "acme/api", number: 88)

    private func makeModel(
        _ config: DeviceConfig = DeviceConfig(features: [.keyLines], login: PRSampleSet.prHubLogin),
        samples: PRSampleSet = .prHub, isOnline: Bool = true
    ) -> PRsModel {
        let model = PRsModel(
            client: PRViewerClient(access: .offline, transport: UnexpectedTransport()), samples: samples,
            storage: .inMemory(), network: PRNetwork(isOnline: isOnline)
        )
        model.featureSource = { PRHubPRHost.configuration(config, locale: Locale(identifier: "en_US")) }
        return model
    }

    private func session(_ model: PRsModel, _ ref: PullRequestRef) throws -> PRSession {
        let row = try #require(model.rows.first { $0.repo == ref.repo && $0.number == ref.number })
        return model.session(for: row)
    }

    // MARK: - A PR's page and its diff

    @Test func thePanelOpensOnKeyLinesAndOnFilesWhenTheWorkerHasNoModel() throws {
        let withModel = try session(makeModel(), Self.checkout)
        #expect(withModel.showsKeyLinesPage && withModel.shownNavigatorPage == .keyLines)

        let noModel = try session(makeModel(DeviceConfig(features: [.push])), Self.checkout)
        #expect(!noModel.showsKeyLinesPage && noModel.shownNavigatorPage == .files, "Files alone, with no key lines")

        // The hosted Worker with no key: the Key lines page stays, to say how to turn them on.
        let noKey = try session(makeModel(DeviceConfig(features: [.push], hosted: true)), Self.checkout)
        #expect(noKey.showsKeyLinesPage && noKey.keyLinesHint != nil)
    }

    @Test func theCheckoutPageSaysItsRiskBugAndRequirementsAndABugOpensItsLine() throws {
        let page = try session(makeModel(), Self.checkout)
        let summary = try #require(page.summary, "the key lines on the phone make the PR at a glance")
        #expect(summary.riskTitle == "Medium risk" && summary.bugsTitle == "1 bug found")
        #expect(summary.requirements?.title == "Requirements mismatch")
        let bug = try #require(summary.bugs.first)

        page.show(bug.asItem)
        #expect(page.selectedKeyLine?.path == bug.path && page.selectedKeyLine?.line == bug.line)
        #expect(page.jump?.path == bug.path && page.jump?.line == bug.line, "the diff goes to the bug's line")
    }

    @Test func aBotsPRNamesWhoItIsForAndItsTitleLeavesOutItsTickets() throws {
        let sample = try #require(PRSampleSet.prHub.samples.first { $0.row.number == Self.rateLimit.number })
        let detail = try PullRequestDetail.decode(Data(sample.detail.utf8))
        #expect(detail.byline == "Mona Lisa via hubot (bot)")
        #expect(detail.title(sample.row.title) == "Rate-limit the password reset endpoint")
        let tickets = try #require(detail.tickets)
        #expect(tickets.map(\.key) == ["API-88", "SEC-12"])
        #expect(tickets[0].title == "Throttle password reset emails" && tickets[0].assignee == "Mona Lisa")
    }

    @Test func theReviewButtonsSayTheirNamesWhateverTheBarShows() {
        let actions: [PRReviewAction] = [.approve, .requestChanges, .comment]
        #expect(actions.map { $0.spokenTitle(yourReview: nil) } == ["Approve", "Request changes", "Comment"])
        #expect(actions.map { $0.spokenTitle(yourReview: .approved) } == ["Approved", "Request changes", "Comment"])
        #expect(actions.map { $0.spokenTitle(yourReview: .changesRequested) } == [
            "Approve", "Changes requested", "Comment",
        ])
    }

    // MARK: - Ask

    private static let question = PRAskChat.Message(id: "m1", role: "you", text: "Is it tested?", anchor: nil)

    @Test func aQuestionTheAgentIsWorkingOnShowsTwoTicks() throws {
        let ask = try session(makeModel(), Self.checkout)
        ask.askChat = PRAskChat(messages: [Self.question], isWorking: true, activity: nil, problem: nil, costCents: nil)
        #expect(ask.isAskWorking)
        #expect(ask.askTicks(at: 0) == .delivered, "the agent has it")
    }

    @Test func anEmptyChatClaimsNoMessageSentAndAWaitingQuestionHasOneTick() throws {
        let ask = try session(makeModel(), Self.checkout)
        ask.askChat = PRAskChat(messages: [], isWorking: false, activity: nil, problem: nil, costCents: nil)
        #expect(ask.askMessages.isEmpty && !ask.isAskWorking)

        ask.askChat = PRAskChat(messages: [Self.question], isWorking: false, activity: nil, problem: nil, costCents: nil)
        #expect(ask.askTicks(at: 0) == .sent, "the Worker has it; the agent has not started")
    }

    // MARK: - The list

    @Test func offlineTheSavedListHasTheOfflineLineAndNoNotUpToDateLine() {
        var samples = PRSampleSet.prHub
        samples.notUpToDate = "GitHub didn't answer."
        let model = makeModel(samples: samples, isOnline: false)
        #expect(!model.rows.isEmpty, "the saved PRs")
        #expect(model.network.offlineWords == "Offline — showing saved information")
        #expect(model.notUpToDateLine == nil, "no second line about the same failure")
    }

    @Test func onlineThereIsNoOfflineLine() {
        var samples = PRSampleSet.prHub
        samples.notUpToDate = "GitHub didn't answer."
        let model = makeModel(samples: samples)
        #expect(model.network.offlineWords == nil)
        #expect(model.notUpToDateLine == "Not up to date. GitHub didn't answer.")
    }

    @Test func anEmptyMergedPageSaysNoneAreMergedBeforeTheInstallHint() async {
        let empty = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
        let model = makeModel(DeviceConfig(features: [.push], hosted: true), samples: empty)
        await model.loadMerged(on: .review)
        #expect(model.emptyState(on: .review, showsMerged: true, pageIsEmpty: true) == .noMerged(.review))
        #expect(
            model.emptyState(on: .review, showsMerged: false, pageIsEmpty: true) == .hint(PRHubPRHost.genericInstallHint),
            "the hint about installing the App is about open PRs"
        )
    }

    @Test func aPRNotSavedOpenedOfflineSaysSoNotThatItFailed() async {
        let offline = makeModel(isOnline: false)
        let unsaved = offline.session(for: PullRequestRef(repo: "acme/web", number: 9999))
        await unsaved.loadIfNeeded()
        #expect(unsaved.isNotSavedOffline)

        let online = makeModel()
        let failed = online.session(for: PullRequestRef(repo: "acme/web", number: 9999))
        await failed.loadIfNeeded()
        #expect(!failed.isNotSavedOffline, "online, the read's failure is said")
    }

    // MARK: - Linear and GitHub access on the hosted Worker

    @Test func aTicketLinearWasNotAskedAboutAsksToConnectItAndOpensLinearInSettings() {
        let unasked = ObjectReference(PRListTicket(key: "API-88"))
        #expect(unasked.asksToConnectLinear(canConnect: true, awaitsLinear: false))
        #expect(!unasked.asksToConnectLinear(canConnect: false, awaitsLinear: false), "where Linear can't be connected")
        #expect(!unasked.asksToConnectLinear(canConnect: true, awaitsLinear: true), "a list still looking it up")
        let found = ObjectReference(PRListTicket(key: "API-88", title: "Throttle password reset emails", found: true))
        #expect(!found.asksToConnectLinear(canConnect: true, awaitsLinear: false))

        let environment = resources.environment()
        environment.navigation.showLinearSettings()
        #expect(environment.navigation.selectedTab == .settings && environment.navigation.settingsSection == .linear)
    }

    // MARK: - Leaving the samples

    /// The 2026-11-10 bug bash: a sign-in refused from the samples left him at onboarding, and what he had done to the
    /// samples was gone when he came back to them.
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
