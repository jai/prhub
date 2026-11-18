import Foundation
@testable import PRHubCore
import Testing

@MainActor
struct AnalyticsEventTests {
    /// One of each case. `kind` has no default, so a new case fails to compile until it is listed here.
    nonisolated static let everyEvent: [AnalyticsEvent] = [
        .screenViewed(.prs), .onboardingPathChosen(.ownWorker), .signInStarted(.onboarding), .signInSucceeded,
        .signInFailed(.denied), .workerPaired, .workerPairingFailed(.codeRefused), .samplesLeft, .anthropicKeySet,
        .anthropicKeyRemoved, .signedOut, .accountDeleted, .workerDisconnected, .diffFontChanged(.menlo, size: 13),
        .pullRequestOpened(.push, .hit, timeToContentMs: 180, networkMs: 0, decodeMs: 40),
        .pullRequestsSynced(.pull, .changed), .pullRequestWriteRefused, .pushPrefetch(.landed, milliseconds: 412),
        .requestFailed(.feedback, .status(404)), .updateOffered(.internal, build: 235), .updateAnswered(.later),
        .listRefreshStarted(rows: 5), .listRefreshFinished(PRListRefreshFinish(
            outcome: .ok, milliseconds: 840, rowsBefore: 5, rowsAfter: 6, source: .network
        )),
        .listRefreshStuck(PRListRefreshStuck(
            gap: 62, offsetY: -124, insetTop: 62, restingInsetTop: 62, isRefreshing: false, isLoading: true,
            isInteracting: false, scene: .active
        )),
        .listRefreshBackgrounded(milliseconds: 1200),
        .feedbackSent(FeedbackSend(kind: .new, images: 1, kilobytes: 412, milliseconds: 1840)),
        .feedbackSendFailed(FeedbackSend(kind: .reply, images: 0, kilobytes: 1, milliseconds: 15000), .timeout),
        .pullRequestWrote(.merge, .failed(.refused)),
        .aiAnswered(.keyLines, .done, milliseconds: 8200, slop: true),
        .askSent(.explainPR, .failed(.offline)), .askAnswerFailed, .askRefused, .askReviewUsed(.posted),
        .askLinearPosted(.failed(.refused)),
    ]

    // swiftlint:disable:next cyclomatic_complexity - one arm per case, by design
    nonisolated static func kind(_ event: AnalyticsEvent) -> Int {
        switch event {
        case .screenViewed: 0
        case .onboardingPathChosen: 1
        case .signInStarted: 2
        case .signInSucceeded: 3
        case .signInFailed: 4
        case .workerPaired: 5
        case .workerPairingFailed: 6
        case .samplesLeft: 7
        case .anthropicKeySet: 8
        case .anthropicKeyRemoved: 9
        case .signedOut: 10
        case .accountDeleted: 11
        case .workerDisconnected: 12
        case .diffFontChanged: 13
        case .pullRequestOpened: 14
        case .pullRequestsSynced: 15
        case .pullRequestWriteRefused: 16
        case .pushPrefetch: 17
        case .requestFailed: 18
        case .updateOffered: 19
        case .updateAnswered: 20
        case .listRefreshStarted: 21
        case .listRefreshFinished: 22
        case .listRefreshStuck: 23
        case .listRefreshBackgrounded: 24
        case .feedbackSent: 25
        case .feedbackSendFailed: 26
        case .pullRequestWrote: 27
        case .aiAnswered: 28
        case .askSent: 29
        case .askAnswerFailed: 30
        case .askRefused: 31
        case .askReviewUsed: 32
        case .askLinearPosted: 33
        }
    }

    // MARK: - What an event can carry

    @Test func everyCaseIsListed() {
        #expect(Set(Self.everyEvent.map(Self.kind)) == Set(0 ... 33))
    }

    @Test func eachEventHasItsOwnSnakeCaseName() {
        let names = Self.everyEvent.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.wholeMatch(of: /\$?[a-z_]+/) != nil, "\(name)")
        }
    }

    /// No case can carry free text: a login, a repo, a path, a title or code would be a String, a URL or a PR's ref.
    @Test(arguments: everyEvent)
    func noEventCarriesTextOrAPullRequest(_ event: AnalyticsEvent) {
        func check(_ value: Any) {
            #expect(!(value is String || value is Substring || value is URL || value is PullRequestRef),
                    "\(event.name) carries \(type(of: value))")
            Mirror(reflecting: value).children.forEach { check($0.value) }
        }
        Mirror(reflecting: event).children.forEach { check($0.value) }
    }

    /// Every word an event sends is one of a closed set, never typed in.
    @Test(arguments: everyEvent)
    func eachWordComesFromAClosedSet(_ event: AnalyticsEvent) {
        let allowed = Set(
            AnalyticsScreen.allCases.map(\.rawValue) + OnboardingPath.allCases.map(\.rawValue)
                + SignInContext.allCases.map(\.rawValue) + SignInFailureCode.allCases.map(\.rawValue)
                + PairingFailureCode.allCases.map(\.rawValue) + DiffFontFace.allCases.map(\.rawValue)
                + PROpenReport.Source.allCases.map(\.rawValue) + PROpenReport.Cache.allCases.map(\.rawValue)
                + PRPushPrefetch.Outcome.allCases.map(\.rawValue)
                + PRRequestArea.allCases.map(\.rawValue) + RequestFailureKind.allCases.map(\.rawValue)
                + TestFlightGroup.allCases.map(\.rawValue) + UpdateAnswer.allCases.map(\.rawValue)
                + PRListRefreshOutcome.allCases.map(\.rawValue) + PRListRefreshSource.allCases.map(\.rawValue)
                + PRListSceneState.allCases.map(\.rawValue) + FeedbackSend.Kind.allCases.map(\.rawValue)
                + PRWriteKind.allCases.map(\.rawValue) + PRActionFailure.allCases.map(\.rawValue)
                + ActionOutcomeWord.allCases.map(\.rawValue) + PRAIKind.allCases.map(\.rawValue)
                + PRAskOrigin.allCases.map(\.rawValue) + PRAskReviewUse.allCases.map(\.rawValue)
                + ["push", "other_push", "foreground", "pull", "changed", "unchanged", "failed"]
        )
        for (key, value) in event.properties {
            #expect(key.wholeMatch(of: /\$?[a-z_]+/) != nil)
            if case let .word(word) = value {
                #expect(allowed.contains(word), "\(event.name).\(key) = \(word)")
            }
        }
    }

    @Test func aPairingFailureDropsTheWorkersHost() {
        let code = PairingFailureCode(.unreachable(host: "pr-worker.octocat.workers.dev"))
        #expect(code == .unreachable)
        #expect(AnalyticsEvent.workerPairingFailed(code).properties == ["code": .word("unreachable")])
    }

    // MARK: - PRKit's events

    @Test func prKitsEventsAreMappedWithoutTheirContent() {
        let ref = PullRequestRef(repo: "acme/checkout", number: 7)
        #expect(AnalyticsEvent(.opened(ref)) == nil, "reported once its content shows")
        let report = PROpenReport(
            source: .push, cache: .miss, timeToContentMilliseconds: 950, networkMilliseconds: 610, decodeMilliseconds: 45
        )
        #expect(AnalyticsEvent(.contentShown(report))
            == .pullRequestOpened(.push, .miss, timeToContentMs: 950, networkMs: 610, decodeMs: 45))
        #expect(AnalyticsEvent(.contentShown(report))?.properties == [
            "source": .word("push"), "cache": .word("miss"), "time_to_content_ms": .number(950),
            "network_ms": .number(610), "decode_ms": .number(45),
        ])
        #expect(AnalyticsEvent(.writeRefused("Branch acme/secret is protected")) == .pullRequestWriteRefused)
        #expect(AnalyticsEvent(.reviewRequests(3)) == nil)
        #expect(AnalyticsEvent(.questionRefused("Is acme/secret tested?")) == .askRefused)
        #expect(AnalyticsEvent(.synced(.pull, .changed)) == .pullRequestsSynced(.pull, .changed))
        #expect(AnalyticsEvent(.synced(.foreground, .unchanged)) == .pullRequestsSynced(.foreground, .unchanged))
    }

    @Test func aFailedRequestSendsItsAreaAndStatusOrWhyThereWasNone() {
        #expect(AnalyticsEvent(.requestFailed(.feedback, .status(404))) == .requestFailed(.feedback, .status(404)))
        #expect(AnalyticsEvent.requestFailed(.feedback, .status(404)).properties == [
            "area": .word("feedback"), "failure": .word("status"), "status": .number(404),
        ])
        #expect(AnalyticsEvent.requestFailed(.diff, .offline).properties == [
            "area": .word("diff"), "failure": .word("offline"),
        ])
    }

    @Test func aWriteSendsWhatItDoesAndHowItWentNeverItsWords() {
        let review = PRWrite.review(.requestChanges, body: "Rename acme_secret", commit: "c", comments: [])
        #expect(AnalyticsEvent(.wrote(PRWriteKind(review), .done)) == .pullRequestWrote(.requestChanges, .done))
        #expect(AnalyticsEvent.pullRequestWrote(.requestChanges, .done).properties == [
            "kind": .word("request_changes"), "outcome": .word("done"),
        ])
        #expect(AnalyticsEvent.pullRequestWrote(.merge, .failed(.offline)).properties == [
            "kind": .word("merge"), "outcome": .word("failed"), "failure": .word("offline"),
        ])
    }

    @Test func anAIAnswerSaysHowItWentAndWhetherTheTrashChipShows() {
        #expect(AnalyticsEvent(.aiAnswered(.keyLines, .done, milliseconds: 8200, slop: true))
            == .aiAnswered(.keyLines, .done, milliseconds: 8200, slop: true))
        #expect(AnalyticsEvent.aiAnswered(.keyLines, .done, milliseconds: 8200, slop: true).properties == [
            "kind": .word("key_lines"), "outcome": .word("done"), "ms": .number(8200), "slop": .number(1),
        ])
        #expect(AnalyticsEvent.aiAnswered(.rewrite, .failed(.refused), milliseconds: 900, slop: nil).properties == [
            "kind": .word("rewrite"), "outcome": .word("failed"), "failure": .word("refused"), "ms": .number(900),
        ])
        #expect(AnalyticsEvent.aiAnswered(.rewrite, .failed(.refused), milliseconds: 900, slop: nil).limitKey
            == AnalyticsEvent.aiAnswered(.rewrite, .failed(.refused), milliseconds: 4000, slop: nil).limitKey)
    }

    @Test func aQuestionSendsWhatAskedItAndHowItWent() {
        #expect(AnalyticsEvent(.askSent(.explainLine, .queued)) == .askSent(.explainLine, .queued))
        #expect(AnalyticsEvent.askSent(.explainPR, .done).properties == [
            "origin": .word("explain_pr"), "outcome": .word("done"),
        ])
        #expect(AnalyticsEvent(.askAnswerFailed) == .askAnswerFailed)
        #expect(AnalyticsEvent(.askReviewUsed(.addedToDrafts))?.properties == ["use": .word("added_to_drafts")])
        #expect(AnalyticsEvent(.askLinearPosted(.failed(.refused)))?.properties == [
            "outcome": .word("failed"), "failure": .word("refused"),
        ])
        #expect(AnalyticsEvent.askAnswerFailed.limitKey == "ask_answer_failed")
        #expect(AnalyticsEvent.askSent(.typed, .done).limitKey == nil)
    }

    /// Only a failure is held back when it repeats: what failed and why, not when or how long it took.
    @Test func aRepeatingFailureIsLimitedByWhatFailedAndWhy() {
        #expect(AnalyticsEvent.pullRequestWrote(.merge, .done).limitKey == nil)
        #expect(AnalyticsEvent.pullRequestWrote(.merge, .failed(.offline)).limitKey == "pr_write merge offline")
        #expect(AnalyticsEvent.pullRequestWrote(.merge, .failed(.offline)).limitKey
            != AnalyticsEvent.pullRequestWrote(.merge, .failed(.timeout)).limitKey)
        #expect(AnalyticsEvent.signedOut.limitKey == nil)
    }

    @Test func aPushesSyncIsReportedOnlyWhenItFails() {
        #expect(AnalyticsEvent(.synced(.silentPush, .changed)) == nil)
        #expect(AnalyticsEvent(.synced(.otherPush, .unchanged)) == nil)
        #expect(AnalyticsEvent(.synced(.silentPush, .failed)) == .pullRequestsSynced(.silentPush, .failed))
    }

    nonisolated static let project = AnalyticsProject(info: [
        "PRHubAnalyticsKey": "phc_example", "PRHubAnalyticsHost": "eu.i.posthog.com",
    ])

    @Test func theProjectComesFromInfoPlist() throws {
        let project = try #require(Self.project)
        #expect(project.apiKey == "phc_example")
        #expect(project.host == URL(string: "https://eu.i.posthog.com"))
    }

    @Test(arguments: [
        [:],
        ["PRHubAnalyticsKey": "", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": " ", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": "$(PRHUB_ANALYTICS_KEY)", "PRHubAnalyticsHost": "eu.i.posthog.com"],
        ["PRHubAnalyticsKey": "phc_example", "PRHubAnalyticsHost": ""],
    ])
    func anEmptyKeyOrHostNamesNoProject(_ info: [String: String]) {
        #expect(AnalyticsProject(info: info) == nil)
    }
}
