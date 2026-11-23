import DurableNetworking
import Foundation
@testable import PRKit
import PRKitTestSupport
import Synchronization
import Testing

/// A PR's Ask AI chat after its sheet closes: followed until it answers, the answer unread until the chat opens again,
/// each PR's chat on its own (Jai's feedback, fb_7cdbe8f2).
@MainActor
struct PRAskActivityTests {
    @MainActor
    final class Host: PRKitHost {
        let access = PRViewerAccess.offline
        let configuration = PRKitConfiguration.everything
        let outbox: (any PRKitOutbox)? = nil
        let apnsEnvironment = "sandbox"
        let samples: PRSampleSet?
        let launchOptions = PRKitLaunchOptions.none
        let transport: any HTTPTransport = UnexpectedTransport()
        func log(_: String) {}
        func receive(_: PRKitEvent) {}

        init(chat: PRAskChat) {
            var samples = PRSampleSet(samples: [], mergedReviewed: [], mergedMine: [], answersOnPhone: true)
            samples.askChat = chat
            self.samples = samples
        }
    }

    private let ref = PullRequestRef(repo: "acme/api", number: 7)
    private let other = PullRequestRef(repo: "acme/web", number: 412)
    private let clock = TestClock()

    private func chat(isWorking: Bool) -> PRAskChat {
        PRAskChat(
            messages: [.init(id: "m1", role: "you", text: "Is it tested?", anchor: nil)],
            isWorking: isWorking, activity: isWorking ? "Reading the repo" : nil, problem: nil, costCents: nil
        )
    }

    private func kit(_ chat: PRAskChat) -> PRKitController {
        let kit = PRKitController(host: Host(chat: chat), storage: .inMemory(), network: PRNetwork(isOnline: true))
        let clock = clock
        kit.model.sleep = { try await clock.sleep(for: $0) }
        return kit
    }

    @Test func aChatThatAnswersAfterItsSheetClosedWaitsAsUnread() async throws {
        let kit = kit(chat(isWorking: false))
        kit.model.askActivities[ref] = PRAskActivity(ref: ref, phase: .working("Thinking"))
        kit.model.followAskAway(ref)
        try await settle("the answer is unread") { kit.model.askActivities[ref]?.phase == .answered }
        #expect(kit.model.askAwayFollows[ref] == nil)
    }

    @Test func aChatStillWorkingSaysWhatTheAgentIsDoingAndIsReadAgain() async throws {
        let kit = kit(chat(isWorking: true))
        kit.model.followAskAway(ref)
        try await settle("working") { kit.model.askActivities[ref]?.phase == .working("Reading the repo") }
        #expect(kit.model.askActivities[ref]?.words == "Reading the repo…")
        try await clock.advance(by: PRSession.askPollInterval, afterSleepers: 1)
        #expect(kit.model.askAwayFollows[ref] != nil, "still read while it works")
        kit.model.askSheetOpened(ref)
    }

    @Test func aReadThatSaysTheSameLeavesTheListAsItIs() async throws {
        let kit = kit(chat(isWorking: true))
        kit.model.followAskAway(ref)
        try await settle("working") { kit.model.askActivities[ref]?.phase == .working("Reading the repo") }
        let isRedrawn = Mutex(false)
        withObservationTracking { _ = kit.model.askActivities } onChange: { isRedrawn.withLock { $0 = true } }
        try await clock.advance(by: PRSession.askPollInterval, afterSleepers: 1)
        // The second read is over once it waits for the third.
        try await clock.advance(by: PRSession.askPollInterval, afterSleepers: 1)
        #expect(!isRedrawn.withLock { $0 })
        kit.model.askSheetOpened(ref)
    }

    @Test func openingTheChatReadsTheAnswerAndStopsFollowing() async throws {
        let kit = kit(chat(isWorking: true))
        kit.model.followAskAway(ref)
        try await settle("working") { kit.model.askActivities[ref] != nil }
        kit.model.askSheetOpened(ref)
        #expect(kit.model.askActivities[ref] == nil)
        #expect(kit.model.askAwayFollows[ref] == nil)
    }

    @Test func eachPRsChatIsItsOwn() async throws {
        let kit = kit(chat(isWorking: false))
        kit.model.askActivities[other] = PRAskActivity(ref: other, phase: .working("Thinking"))
        kit.model.followAskAway(ref)
        try await settle("this PR's answer") { kit.model.askActivities[ref]?.phase == .answered }
        #expect(kit.model.askActivities[other]?.phase == .working("Thinking"))
        kit.model.askSheetOpened(ref)
        #expect(kit.model.askActivities.keys.sorted { $0.number < $1.number } == [other])
    }

    @Test func theOpenSheetSaysWorkingThenNothingOnceItAnswersInSight() {
        let kit = kit(chat(isWorking: false))
        kit.model.askSheetRead(ref, chat: chat(isWorking: true), isOnItsWay: false)
        #expect(kit.model.askActivities[ref]?.phase == .working("Reading the repo"))
        kit.model.askSheetRead(ref, chat: chat(isWorking: false), isOnItsWay: false)
        #expect(kit.model.askActivities[ref] == nil)
        kit.model.askSheetRead(ref, chat: nil, isOnItsWay: true)
        #expect(kit.model.askActivities[ref]?.isWorking == true, "a question on its way counts as working")
    }
}
