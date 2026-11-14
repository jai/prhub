import Foundation
import PRKit
import SwiftUI
import Testing
@testable import FeatureKit

@MainActor
struct FeatureConversationTests {
    private let thread = FeatureAgentThread(host: "builder", id: "codex:session-1")
    private let route = FeatureRoute.thread("sesn_1")

    private func model(delivery: [String: FeatureMessageDelivery] = [:]) async -> FeatureRequestsModel {
        let thread = thread
        let samples = FeatureSamples(
            list: FeatureList(threads: [], builderOnline: true),
            chat: { FeatureChat(
                id: $0, messages: [], isWorking: false, activity: nil, problem: nil,
                costCents: nil, builderOnline: true, thread: thread, delivery: delivery
            ) }, answer: "Got it."
        )
        let access = PRViewerAccess(
            baseURL: { URL(string: "https://worker.example.com")! }, bearer: { "token" }, discard: {}
        )
        let model = FeatureRequestsModel(client: FeatureClient(
            access: access, isInForeground: { true }, samples: samples
        ))
        await model.follow(route)
        return model
    }

    @Test func everyUndeliveredStateKeepsTheExistingFeedbackHistory() async {
        for state in [FeatureMessageDelivery.pending, .delivering, .failed, .unknown] {
            let model = await model(delivery: ["old-message": state])
            var called = false
            let view = FeatureChatView(model: model, route: route, conversation: { _ in
                called = true
                return AnyView(EmptyView())
            })

            #expect(view.hostedConversation == nil)
            #expect(!called)
        }
    }

    @Test func theHostReceivesTheSameDraftBindingAndAttachmentTray() async throws {
        let model = await model(delivery: ["old-message": .delivered])
        model.drafts[route.box] = "The next change"
        let attachments = model.attachments(for: route.box)
        var received: FeatureConversation?
        let view = FeatureChatView(model: model, route: route, conversation: { context in
            received = context
            return AnyView(EmptyView())
        })

        #expect(view.hostedConversation != nil)
        let context = try #require(received)
        #expect(context.thread == thread)
        #expect(context.draft.wrappedValue == "The next change")
        #expect(context.attachments === attachments)
        context.draft.wrappedValue = ""
        #expect(model.draft(for: route.box).isEmpty)
    }

    @Test func theHostCanKeepFeedbackWhileItsThreadIsUnavailable() async {
        let model = await model()
        var received: FeatureAgentThread?
        let view = FeatureChatView(model: model, route: route, conversation: { context in
            received = context.thread
            return nil
        })

        #expect(view.hostedConversation == nil)
        #expect(received == thread)
        #expect(view.awaitsAgentThread)
    }

    @Test func anEarlierFailedMessageExplainsWhyTheChatCannotHandOff() async {
        let model = await model(delivery: ["old-message": .failed, "newer-message": .delivered])
        let view = FeatureChatView(model: model, route: route, conversation: { _ in AnyView(EmptyView()) })

        #expect(view.hostedConversation == nil)
        #expect(view.handoffProblem == "An earlier message did not reach the agent. Start new feedback to continue.")
    }

    @Test func onlyAHostedChatThatHasStartedBlocksTheFeedbackComposer() async {
        let model = await model()
        let hosted: (FeatureConversation) -> AnyView? = { _ in nil }
        let first = FeatureChatView(model: model, route: .new(UUID()), conversation: hosted)
        let started = FeatureChatView(model: model, route: route, conversation: hosted)
        let standalone = FeatureChatView(model: model, route: route, conversation: nil)

        #expect(!first.awaitsAgentThread)
        #expect(started.awaitsAgentThread)
        #expect(!standalone.awaitsAgentThread)
        #expect(standalone.hostedConversation == nil)
    }

    @Test func deliveryMetadataKeepsUnknownUserMessagesAndIgnoresAgentMessages() throws {
        let json = #"{"id":"sesn_1","isWorking":false,"builderOnline":true,"messages":["#
            + #"{"id":"one","role":"you","text":"First","status":"delivered"},"#
            + #"{"id":"two","role":"you","text":"Second","status":"queued"},"#
            + #"{"id":"three","role":"you","text":"Third"},"#
            + #"{"id":"answer","role":"agent","text":"Working"}]}"#
        let chat = try JSONDecoder().decode(FeatureChat.self, from: Data(json.utf8))

        #expect(chat.delivery == ["one": .delivered, "two": .unknown, "three": .unknown])
        #expect(chat.hasUndeliveredMessages)
    }

    @Test func hostedDiscoveryContinuesAfterTheAgentBecomesIdleOrAReadFails() {
        var chat = FeatureChat(
            id: "sesn_1", messages: [], isWorking: false, activity: nil, problem: nil,
            costCents: nil, builderOnline: true
        )
        #expect(!FeatureFollowMode.whileWorking.keepsReading(chat))
        #expect(FeatureFollowMode.untilHandoff.keepsReading(chat))
        #expect(FeatureFollowMode.untilHandoff.keepsReading(nil))
        chat.isWorking = true
        #expect(FeatureFollowMode.whileWorking.keepsReading(chat))
    }
}
