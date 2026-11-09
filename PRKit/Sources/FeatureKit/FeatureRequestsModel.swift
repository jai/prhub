import Foundation
import Observation
import PRKit
import SwiftUI

/// Words on their way, shown as sent until the chat has them.
struct PendingMessage: Equatable, Sendable {
    var text: String
    var screenshots: Int
}

/// A conversation open on the screen: one started here and not sent yet (or just sent), or one in the list. A new one
/// keeps its route after its first message makes it a thread, so it goes on in place.
enum FeatureRoute: Hashable, Sendable {
    case new(UUID)
    case thread(String)

    /// Its draft, screenshots and words on their way.
    var box: String {
        switch self {
        case .new(let id): "new-\(id.uuidString)"
        case .thread(let id): id
        }
    }
}

/// Requests for changes to the app, each a conversation with an agent that makes the change, tests it and ships a
/// build. Keep one for the app's life, so drafts and open chats outlive the screen.
@MainActor
@Observable
public final class FeatureRequestsModel {
    static let pollInterval: Duration = .seconds(3)

    private(set) var list = FeatureList(threads: [], builderOnline: false)
    private(set) var chats: [String: FeatureChat] = [:]
    private(set) var error: String?
    /// Unsent words, one box per conversation (`FeatureRoute.box`).
    var drafts: [String: String] = [:]
    /// The words on their way, by box, shown as sent until the chat has them.
    private(set) var pending: [String: PendingMessage] = [:]
    /// The thread each new conversation became with its first message.
    private(set) var started: [UUID: String] = [:]
    /// The screenshots in each box, kept with its draft.
    @ObservationIgnored private var attachmentBoxes: [String: ComposerAttachments] = [:]
    /// Which boxes are sending.
    private(set) var sending: Set<String> = []
    /// The boxes the sample screenshot went into once.
    @ObservationIgnored private var seeded: Set<String> = []
    private let client: FeatureClient

    public init(client: FeatureClient) {
        self.client = client
    }

    func draft(for box: String) -> String { drafts[box] ?? "" }

    func isSending(_ box: String) -> Bool { sending.contains(box) }

    /// The thread a conversation is, once it is one.
    func thread(for route: FeatureRoute) -> String? {
        switch route {
        case .new(let id): started[id]
        case .thread(let id): id
        }
    }

    /// A new conversation to write in: the one already started and still empty, else a fresh one.
    func compose(reusing route: FeatureRoute?) -> FeatureRoute {
        if case .new(let id) = route, started[id] == nil {
            return .new(id)
        }
        return .new(UUID())
    }

    /// Its title: the list's, else the first words sent, else nothing yet.
    func title(for route: FeatureRoute) -> String? {
        guard let id = thread(for: route) else {
            return nil
        }
        return list.threads.first { $0.id == id }?.title
            ?? chats[id]?.messages.first { $0.isJai }?.text
            ?? pending[route.box]?.text
    }

    func attachments(for box: String) -> ComposerAttachments {
        if let attachments = attachmentBoxes[box] {
            return attachments
        }
        let attachments = ComposerAttachments()
        attachmentBoxes[box] = attachments
        return attachments
    }

    func binding(for box: String) -> Binding<String> {
        Binding(get: { self.drafts[box] ?? "" }, set: { self.drafts[box] = $0.isEmpty ? nil : $0 })
    }

    /// The host app's build, sent with each message so the agent knows what the sender is looking at.
    private var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    func refresh() async {
        if let samples = client.samples {
            if list.threads.isEmpty {
                list = samples.list
            }
            return
        }
        do {
            list = try await client.list()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The conversation's draft, to its thread, or as a new request before it has one: that makes the thread.
    func send(_ route: FeatureRoute) async {
        let box = route.box
        let thread = thread(for: route)
        let text = draft(for: box).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachments(for: box)
        guard !text.isEmpty || !attachments.isEmpty, !sending.contains(box) else {
            return
        }
        sending.insert(box)
        error = nil
        let screenshots = attachments.take()
        pending[box] = PendingMessage(text: text, screenshots: screenshots.count)
        drafts[box] = nil
        defer {
            sending.remove(box)
            pending[box] = nil
        }
        do {
            let message = FeatureMessage(
                text: text, build: build, images: screenshots.map { MessageImage(jpeg: $0.jpeg) },
                client_ref: UUID().uuidString
            )
            if let samples = client.samples {
                try await sendSample(message, thread: thread, route: route, answer: samples.answer)
                return
            }
            let chat = try await client.send(message, to: thread)
            chats[chat.id] = chat
            if case .new(let id) = route, thread == nil {
                started[id] = chat.id
                await refresh()
            }
        } catch {
            drafts[box] = text
            attachments.restore(screenshots)
            self.error = error.localizedDescription
        }
    }

    /// `FeatureSamples`: a send the agent answers a moment later, so a test and a recording see the whole round.
    private func sendSample(_ message: FeatureMessage, thread: String?, route: FeatureRoute, answer: String)
        async throws {
        try await Task.sleep(for: .milliseconds(600))
        let id = thread ?? "sesn_new_\(list.threads.count)"
        var chat = chats[id] ?? FeatureChat(
            id: id, messages: [], isWorking: false, activity: nil, problem: nil, costCents: 0, builderOnline: true
        )
        chat.messages.append(.init(id: "\(chat.messages.count + 1)", role: "you", text: message.text, anchor: nil))
        chat.isWorking = true
        chat.activity = "Reading the app"
        chats[id] = chat
        if case .new(let started) = route, thread == nil {
            self.started[started] = id
            list.threads.insert(FeatureThread(id: id, title: message.text, createdAt: Date.now.ISO8601Format()), at: 0)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard var chat = chats[id] else {
                return
            }
            chat.messages.append(.init(id: "\(chat.messages.count + 1)", role: "agent", text: answer, anchor: nil))
            chat.isWorking = false
            chat.activity = nil
            chats[id] = chat
        }
    }

    /// While a chat shows: every few seconds while the agent works or a message is on its way, and once otherwise.
    func follow(_ route: FeatureRoute) async {
        guard let thread = thread(for: route) else {
            return
        }
        if let samples = client.samples {
            if chats[thread] == nil {
                chats[thread] = samples.chat(thread)
            }
            return
        }
        while !Task.isCancelled {
            do {
                chats[thread] = try await client.chat(thread)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            guard chats[thread]?.isWorking == true || sending.contains(route.box) else {
                return
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// `FeatureSamples.screenshot`: a box starts with it in its tray, once.
    func seedScreenshot(in box: String) async {
        guard let screenshot = client.samples?.screenshot else {
            return
        }
        let attachments = attachments(for: box)
        if attachments.isEmpty, !seeded.contains(box) {
            seeded.insert(box)
            await attachments.add(screenshot)
        }
    }
}
