import DurableNetworking
import Foundation
@testable import PRKit
import PRKitTestSupport
import Testing

@MainActor
struct PRScreenModelTests {
    private let ref = PullRequestRef(repo: "acme/web", number: 7)
    private static let keyLines = #"""
    {"items":[{"path":"a.swift","line":1,"side":"RIGHT","kind":"risk","why":"Check the retry"},
              {"path":"a.swift","line":2,"side":"RIGHT","kind":"logic","why":"Check the fallback"}],
     "context":100,"leftOut":[],"summary":{"risk":"medium","riskWhy":"Retry behavior","points":[],
       "bugs":[{"path":"a.swift","line":1,"side":"RIGHT","why":"No retry"}],
       "slop":{"isSlop":true,"tells":["Boilerplate description"]}}}
    """#

    private func samples(answersOnPhone: Bool = true) -> PRSampleSet {
        let row = PullRequestRow(
            repo: ref.repo, number: ref.number, title: "Retry uploads", head: "h", revision: "sample",
            diff: .ready, detail: "sample", status: nil, keyLines: 100
        )
        return PRSampleSet(samples: [.init(
            row: row, detail: PRTestPayload.detail(),
            diff: "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -0,0 +1,2 @@\n+retry()\n+fallback()\n",
            keyLines: Self.keyLines
        )], mergedReviewed: [], mergedMine: [], answersOnPhone: answersOnPhone)
    }

    private func model(
        _ configuration: PRKitConfiguration = .everything, samples: PRSampleSet? = nil, isOnline: Bool = true,
        access: PRViewerAccess = .offline
    ) -> PRsModel {
        let model = PRsModel(
            client: PRViewerClient(access: access, transport: UnexpectedTransport()), samples: samples ?? self.samples(),
            storage: .inMemory(), network: PRNetwork(isOnline: isOnline)
        )
        model.featureSource = { configuration }
        return model
    }

    private func session(_ model: PRsModel) throws -> PRSession {
        try model.session(for: #require(model.rows.first))
    }

    private var hint: PREmptyHint {
        PREmptyHint(title: "Enable AI", message: "Add a key", linkTitle: "Settings", link: URL(string: "https://example.com/settings")!)
    }

    @Test func thePanelUsesKeyLinesWhenEnabledOrExplainedAndFilesOtherwise() throws {
        let enabled = try session(model())
        #expect(enabled.showsKeyLinesPage && enabled.shownNavigatorPage == .keyLines)
        let disabled = PRKitConfiguration(features: [], orgDefault: .everyOwner)
        let files = try session(model(disabled))
        #expect(!files.showsKeyLinesPage && files.shownNavigatorPage == .files)
        var explained = disabled
        explained.keyLinesHint = hint
        let unavailable = try session(model(explained))
        #expect(unavailable.showsKeyLinesPage && unavailable.keyLinesHint == hint)
    }

    @Test func aSummaryBugSelectsAndJumpsToItsLine() throws {
        let page = try session(model())
        let bug = try #require(page.summary?.bugs.first)
        page.show(bug.asItem)
        #expect(page.selectedKeyLine?.path == bug.path && page.selectedKeyLine?.line == bug.line)
        #expect(page.jump?.path == bug.path && page.jump?.line == bug.line)
    }

    @Test func aBotsBylineNamesTheHumanAndItsTitleLeavesOutItsTickets() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(PRTestPayload.detail().utf8)) as? [String: Any])
        json["author"] = ["login": "hubot", "name": NSNull(), "avatarUrl": NSNull()]
        json["authorIsBot"] = true
        json["requestedBy"] = ["login": "octocat", "name": "Mona Lisa", "avatarUrl": NSNull(), "source": "co_author"]
        json["tickets"] = [
            ["key": "ENG-7", "title": "Retry uploads", "assignee": "Mona Lisa", "found": true],
            ["key": "SEC-12", "title": "Check retries", "found": true],
        ]
        let detail = try PullRequestDetail.decode(JSONSerialization.data(withJSONObject: json))
        #expect(detail.byline == "Mona Lisa via hubot (bot)")
        #expect(detail.requesterShortName == "Mona" && detail.agent == nil, "no ticket is delegated")
        #expect(detail.title("Retry uploads [ENG-7, SEC-12]") == "Retry uploads")
        let tickets = try #require(detail.tickets)
        #expect(tickets.map(\.key) == ["ENG-7", "SEC-12"])
        #expect(tickets[0].title == "Retry uploads" && tickets[0].assignee == "Mona Lisa")
    }

    @Test func anAgentsBylineShowsTheAgentLinearDelegatedTheTicketTo() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(PRTestPayload.detail().utf8)) as? [String: Any])
        json["author"] = ["login": "agent-atlas", "name": NSNull(), "avatarUrl": "https://avatars.example/account"]
        json["authorIsBot"] = true
        json["requestedBy"] = [
            "login": NSNull(), "name": "Alex Doe", "avatarUrl": "https://avatars.example/alex", "source": "linear",
        ]
        json["tickets"] = [
            ["key": "SEC-12", "assignee": "Mona Lisa", "delegate": "Other Agent", "found": true],
            ["key": "ENG-7", "assignee": "Alex Doe", "delegate": "Atlas",
             "delegate_avatar": "https://avatars.example/atlas", "found": true],
        ]
        let detail = try PullRequestDetail.decode(JSONSerialization.data(withJSONObject: json))
        #expect(detail.requesterShortName == "Alex")
        #expect(detail.agent?.login == "Atlas", "the delegate of the ticket that named the person")
        #expect(detail.agent?.avatarUrl == "https://avatars.example/atlas", "Linear's picture, not the GitHub account's")
        #expect(detail.byline == "Alex Doe via Atlas, agent-atlas (bot)")
        json["authorIsBot"] = false
        let person = try PullRequestDetail.decode(JSONSerialization.data(withJSONObject: json))
        #expect(person.agent == nil && person.requesterShortName == nil && person.byline == "agent-atlas")
    }

    @Test func reviewButtonsSpeakTheirStandingReview() {
        let actions: [PRReviewAction] = [.approve, .requestChanges, .comment]
        #expect(actions.map { $0.spokenTitle(yourReview: nil) } == ["Approve", "Request changes", "Comment"])
        #expect(actions.map { $0.spokenTitle(yourReview: .approved) } == ["Approved", "Request changes", "Comment"])
        #expect(actions.map { $0.spokenTitle(yourReview: .changesRequested) } == ["Approve", "Changes requested", "Comment"])
    }

    @Test func aWorkingQuestionHasTwoTicksAndAWaitingOneHasOne() throws {
        let ask = try session(model())
        let question = PRAskChat.Message(id: "m1", role: "you", text: "Is it tested?", anchor: nil)
        ask.askChat = PRAskChat(messages: [question], isWorking: true, activity: nil, problem: nil, costCents: nil)
        #expect(ask.isAskWorking && ask.askTicks(at: 0) == .delivered)
        ask.askChat = PRAskChat(messages: [], isWorking: false, activity: nil, problem: nil, costCents: nil)
        #expect(ask.askMessages.isEmpty && !ask.isAskWorking)
        ask.askChat = PRAskChat(messages: [question], isWorking: false, activity: nil, problem: nil, costCents: nil)
        #expect(ask.askTicks(at: 0) == .sent)
    }

    @Test func anOfflineListDoesNotRepeatItsProblemInTheNotUpToDateLine() {
        var samples = samples()
        samples.notUpToDate = "GitHub didn't answer."
        let offline = model(samples: samples, isOnline: false)
        #expect(!offline.rows.isEmpty)
        #expect(offline.network.offlineWords == "Offline — showing saved information")
        #expect(offline.notUpToDateLine == nil)
        let online = model(samples: samples)
        #expect(online.network.offlineWords == nil)
        #expect(online.notUpToDateLine == "Not up to date. GitHub didn't answer.")
    }

    @Test func anEmptyMergedPageComesBeforeTheHostsInstallHint() async {
        let empty = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
        var configuration = PRKitConfiguration.everything
        configuration.emptyHint = hint
        let model = model(configuration, samples: empty)
        await model.loadMerged(on: .review)
        #expect(model.emptyState(on: .review, showsMerged: true, pageIsEmpty: true) == .noMerged(.review))
        #expect(model.emptyState(on: .review, showsMerged: false, pageIsEmpty: true) == .hint(hint))
    }

    @Test func aPRNotSavedOfflineHasItsOwnStateInsteadOfAReadFailure() async {
        let missing = PullRequestRef(repo: "acme/web", number: 99)
        let offline = model(isOnline: false).session(for: missing)
        await offline.loadIfNeeded()
        #expect(offline.isNotSavedOffline)
        let online = model().session(for: missing)
        await online.loadIfNeeded()
        #expect(!online.isNotSavedOffline)
    }

    @Test func anUnresolvedTicketOffersLinearOnlyWhenItCanBeConnectedAndIsNotLoading() {
        let unresolved = ObjectReference(PRListTicket(key: "ENG-7"))
        #expect(unresolved.asksToConnectLinear(canConnect: true, awaitsLinear: false))
        #expect(!unresolved.asksToConnectLinear(canConnect: false, awaitsLinear: false))
        #expect(!unresolved.asksToConnectLinear(canConnect: true, awaitsLinear: true))
        let found = ObjectReference(PRListTicket(key: "ENG-7", title: "Retry uploads", found: true))
        #expect(!found.asksToConnectLinear(canConnect: true, awaitsLinear: false))
    }

    @Test func theOrgDefaultSelectsItsOwnersOrEveryOwner() {
        let owners = ["acme", "beta", "gamma"]
        #expect(PROrgDefault.orgs(["acme"]).filter(owners: owners).selected == ["acme"])
        #expect(PROrgDefault.everyOwner.filter(owners: owners).selected == Set(owners))
    }

    @Test func sampleKeyLinesAnswerAtAnyContextAndUnsupportedAIIsRefused() async throws {
        let model = model()
        var events: [PRKitEvent] = []
        model.onEvent = { events.append($0) }
        let lines: PRKeyLines = try await model.aiAnswer("key-lines", ref: ref, head: "h", context: 10, retry: false)
        #expect(lines.items.count == 2)
        await #expect(throws: PRLocalRefusal.sampleAI) {
            let _: PRRewrite = try await model.aiAnswer("rewrite", ref: ref, head: "h", retry: true)
        }
        #expect(events.count == 2)
        guard case .aiAnswered(.keyLines, .done, _, true) = events.first,
              case .aiAnswered(.rewrite, .failed(.local), _, nil) = events.last
        else {
            Issue.record("sample AI must report its result")
            return
        }
    }

    @Test func aSampleReviewAndCommentStayInTheReopenedConversation() async throws {
        let model = model()
        let detail = try #require(try await model.write(.review(.approve, body: "Ship it", commit: "h", comments: []), to: ref).posted)
        #expect(detail.reviews.nodes.last?.state == "APPROVED" && detail.reviews.nodes.last?.body == "Ship it")
        #expect(model.writeNotice == .sampleOnly)
        #expect(try session(model).content?.detail.reviews.nodes.last?.body == "Ship it")
        let commented = try #require(try await model.write(.comment(body: "Nice one"), to: ref).posted)
        #expect(commented.comments.nodes.last?.body == "Nice one")
        #expect(try session(model).content?.detail.comments.nodes.last?.body == "Nice one")
    }

    @Test func sampleReadsWritesAndAIReachNoConfiguredTransport() async throws {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "test" }, discard: {})
        let model = model(access: access)
        #expect(await model.refresh(.foreground) == .unchanged)
        await model.loadMerged(on: .review)
        #expect(model.merged[.review]?.isEmpty == true)
        _ = try await model.write(.comment(body: "Stayed here"), to: ref)
        let _: PRKeyLines = try await model.aiAnswer("key-lines", ref: ref, head: "h", retry: false)
    }

    @Test func aSampleSetThatDoesNotAnswerOnThePhoneRefusesWrites() async throws {
        let model = model(samples: samples(answersOnPhone: false))
        await #expect(throws: PRLocalRefusal.sampleWrite) {
            try await model.write(.comment(body: "x"), to: ref)
        }
        #expect(model.writeNotice == nil)
    }

    @Test func anOfflineClientRefusesAnOutboxRequestBeforeTransport() async {
        let client = PRViewerClient(access: .offline, transport: UnexpectedTransport())
        await #expect(throws: PRWorkerError.notPaired) {
            try await client.outboxRequest(path: "prs/acme/web/7/write", body: Data("{}".utf8))
        }
    }
}
