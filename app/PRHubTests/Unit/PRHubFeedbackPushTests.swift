import FeatureKit
import Foundation
@testable import PRHubCore
import PRHubTestSupport
@testable import PRKit
import Testing
import UserNotifications

/// FeedbackKit's own pushes on PRHub: the phone registers with FeedbackKit once it has both its APNs token and the
/// direct path, a tapped push opens its chat in Feedback, and each account keeps its own Feedback list.
struct PRHubFeedbackPushTests {
    private struct Refused: Error {}

    /// What FeedbackKit was sent: `+token` registered, `-token` unregistered.
    private static func devices(
        _ sent: Shared<[String]>, refusing: Shared<Bool> = Shared(false)
    ) async -> PRHubFeedbackDevices {
        let devices = PRHubFeedbackDevices()
        await devices.connected(
            register: { token in
                if refusing.with({ $0 }) {
                    throw Refused()
                }
                sent.with { $0.append("+\(token)") }
            },
            unregister: { token in sent.with { $0.append("-\(token)") } }
        )
        return devices
    }

    @Test func theTokenAndThePathRegisterInEitherOrderAndOnce() async {
        let sent = Shared<[String]>([])
        let pathFirst = await Self.devices(sent)
        #expect(sent.with { $0 }.isEmpty, "no token yet: nothing to register")
        await pathFirst.tokenArrived("aa")
        await pathFirst.tokenArrived("aa")
        await pathFirst.retry()
        #expect(sent.with { $0 } == ["+aa"])

        let tokenFirst = PRHubFeedbackDevices()
        await tokenFirst.tokenArrived("bb")
        #expect(sent.with { $0 } == ["+aa"], "no direct path yet: nothing to register with")
        await tokenFirst.connected(register: { token in sent.with { $0.append("+\(token)") } }, unregister: { _ in })
        #expect(sent.with { $0 } == ["+aa", "+bb"])
    }

    @Test func aRefusedRegistrationGoesAgainAtTheNextForeground() async {
        let sent = Shared<[String]>([])
        let refusing = Shared(true)
        let devices = await Self.devices(sent, refusing: refusing)
        await devices.tokenArrived("aa")
        #expect(sent.with { $0 }.isEmpty)
        refusing.with { $0 = false }
        await devices.retry()
        #expect(sent.with { $0 } == ["+aa"])
    }

    @Test func anotherPathRegistersAgainAndALeavingAccountUnregisters() async {
        let sent = Shared<[String]>([])
        let devices = await Self.devices(sent)
        await devices.tokenArrived("aa")
        await devices.forget()
        await devices.forget()
        #expect(sent.with { $0 } == ["+aa", "-aa"], "unregistered once")

        await devices.connected(register: { token in sent.with { $0.append("+\(token)@next") } }, unregister: { _ in })
        #expect(sent.with { $0 } == ["+aa", "-aa", "+aa@next"], "another account's path takes the same token")

        await devices.disconnected()
        await devices.tokenArrived("cc")
        await devices.forget()
        #expect(sent.with { $0 }.count == 3, "off the direct path nothing is sent")
    }

    @Test func eachAccountOnEachWorkerHasItsOwnKeptList() throws {
        let direct = try JSONDecoder().decode(DeviceConfig.self, from: Data(
            #"{"features":{"feedback":true},"login":"Octo Cat","feedback_direct":{"url":"https://feedback.example.com"}}"#.utf8
        ))
        let path = PRHubFeedbackPath(host: "prhub.example.com", config: direct)
        #expect(path.root == URL(string: "https://feedback.example.com"))
        #expect(path.account == "prhub.example.com-octo_cat", "one folder name, whatever the login holds")

        var hosted = direct
        hosted.account = DeviceConfig.Account(state: .signedIn, login: "octocat", userId: "4242")
        #expect(PRHubFeedbackPath(host: "prhub.example.com", config: hosted).account == "prhub.example.com-4242")
        #expect(PRHubFeedbackPath(host: "other.example.com", config: hosted) != PRHubFeedbackPath(
            host: "prhub.example.com", config: hosted
        ))

        #expect(PRHubFeedbackPath(host: "prhub.example.com", config: nil) == PRHubFeedbackPath())
        #expect(PRHubFeedbackPath(host: nil, config: direct).account == nil)
        #expect(PRHubFeedbackPath.accountName(host: "h", person: "../../x") == "h-.._.._x")
        #expect(PRHubFeedbackPath().keep == nil, "no account named: nothing is kept")

        // An account that leaves, or is replaced, takes its kept list with it; a moved root alone does not.
        let other = PRHubFeedbackPath(root: path.root, account: "prhub.example.com-4242")
        #expect(path.leavesItsAccount(for: PRHubFeedbackPath()))
        #expect(path.leavesItsAccount(for: other))
        #expect(!path.leavesItsAccount(for: PRHubFeedbackPath(root: nil, account: path.account)))
        #expect(!PRHubFeedbackPath().leavesItsAccount(for: path), "a first sign-in leaves nobody")
    }

    private nonisolated(unsafe) static let reply: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Mac feedback", "body": "Shipped in build 312."]],
        "feedbackkit": ["chat": "fb_3edc7ec3310c4e9e", "app": "prhub", "kind": "reply"],
    ]

    @MainActor @Test func tappingAFeedbackPushOpensItsChatAndDismissingOpensNothing() async {
        let opened = Shared<[String]>([])
        let delegate = PRHubNotificationDelegate(
            open: { _, _ in opened.with { $0.append("a PR") } }, openFeedback: { chat in opened.with { $0.append(chat) } }
        )
        let chat = FeedbackPush(userInfo: Self.reply)?.chat
        for action in [UNNotificationDismissActionIdentifier, UNNotificationDefaultActionIdentifier] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                delegate.respond(
                    action: action, pullRequest: PRPush(userInfo: Self.reply)?.openedPullRequest, feedbackChat: chat
                ) {
                    continuation.resume()
                }
            }
        }
        #expect(opened.with { $0 } == ["fb_3edc7ec3310c4e9e"])
    }

    /// Feedback's badge counts from a feedback chat's push, in front or tapped; a PR's alert is no news of a chat.
    @MainActor @Test func aFeedbackPushReachesTheBadgeAndAPRsAlertDoesNot() async {
        let (pushes, arrivals) = AsyncStream<FeedbackPush>.makeStream()
        let delegate = PRHubNotificationDelegate(open: { _, _ in }, feedbackPush: { arrivals.yield($0) })
        delegate.arrived(["aps": ["alert": "Review requested"], "repo": "acme/web", "number": 412])
        var question = Self.reply
        question["feedbackkit"] = ["chat": "fb_3edc7ec3310c4e9e", "app": "prhub", "kind": "reply", "asks": true]
        delegate.arrived(question)
        var arrived = pushes.makeAsyncIterator()
        #expect(await arrived.next() == FeedbackPush(chat: "fb_3edc7ec3310c4e9e", app: "prhub", kind: .reply, asks: true))
    }

    /// The badge counts only where there is a Feedback to open: a paired Worker that serves it.
    @MainActor @Test func feedbackIsBadgedOnlyWhereTheWorkerServesIt() {
        let resources = UnitResources()
        let serving = resources.paired(features: [.feedback])
        #expect(serving.badgedFeedback === serving.feedback)
        #expect(resources.paired(features: []).badgedFeedback == nil)
        #expect(resources.sample().badgedFeedback == nil, "the samples have no Feedback")
    }

    @MainActor @Test func anOpenedFeedbackChatShowsFeedbackOnlyWhereTheWorkerServesIt() {
        let resources = UnitResources()
        let serving = resources.paired(features: [.feedback])
        serving.openFeedbackChat("fb_one")
        #expect(serving.navigation.selectedTab == .feedback)
        #expect(serving.navigation.feedbackChat?.chat == "fb_one")
        let first = serving.navigation.feedbackChat
        serving.openFeedbackChat("fb_one")
        #expect(serving.navigation.feedbackChat != first, "the same chat's next push opens it again")

        let without = resources.paired(features: [])
        without.openFeedbackChat("fb_one")
        #expect(without.navigation.selectedTab == .prs)
        #expect(without.navigation.feedbackChat == nil)

        let sample = resources.sample()
        sample.openFeedbackChat("fb_one")
        #expect(sample.navigation.feedbackChat == nil, "the samples have no Feedback")
    }
}
