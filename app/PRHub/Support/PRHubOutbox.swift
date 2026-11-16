import DurableNetworking
import Foundation
import PRKit

/// PR writes and Ask questions on their way to the Worker (`PRKitOutbox`): saved on the device first, then sent until
/// the Worker answers, through a dead zone, a kill or a relaunch (DurableNetworking's `Outbox`). Each carries its id as
/// `client_ref`, so however many attempts land the Worker posts it once (`worker/src/write-receipts.ts`). Merges and
/// branch updates never come here (`PRsModel+Outbox`). Disconnect and sign out empty it, so nothing goes to another
/// Worker.
@MainActor
final class PRHubOutbox: PRKitOutbox {
    /// Where it is saved: Application Support, which iOS keeps.
    static let file = URL.applicationSupportDirectory.appending(path: "pr-outbox.json")

    weak var kit: PRKitController?
    private var items: [OutboxItem] = []
    private var revision = -1
    private var watcher: PathWatcher?
    // The outbox's hooks capture self, so it is made last in init; it is never nil after init returns.
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var outbox: Outbox!

    /// `send` makes one try; the outbox does the waiting and the trying again. `file` nil keeps it in memory.
    init(client: PRViewerClient, file: URL? = PRHubOutbox.file, send: (any HTTPTransport)? = nil) {
        let transport = send ?? AppNetwork.oneTry
        var hooks = Outbox.Hooks()
        hooks.changed = { [weak self] in await self?.refresh() }
        hooks.accepted = { [weak self] item, data in await self?.accepted(item, data) }
        hooks.rejected = { [weak self] item, reason in await self?.rejected(item, reason) }
        outbox = Outbox(file: file, hooks: hooks) { item in
            await Self.attempt(item, client: client, transport: transport)
        }
    }

    /// Sends what an earlier launch left, and again each time a network comes back. Before this nothing goes out.
    func start() {
        guard watcher == nil else {
            return
        }
        watcher = PathWatcher(returned: { [weak self] in Task { await self?.outbox.kick() } })
        Task {
            await outbox.start()
            await refresh()
        }
    }

    func enqueue(_ job: PROutboxJob) async throws -> String {
        let id = UUID().uuidString
        let ref = job.ref
        let (route, encoded) = switch job {
        case let .write(write, _): try ("write", JSONEncoder().encode(write))
        case let .question(question, _): try ("ask", JSONEncoder().encode(question))
        }
        var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        fields["client_ref"] = id
        let item = try OutboxItem(
            id: id, lane: Self.lane(ref), path: "prs/\(ref.repo)/\(ref.number)/\(route)",
            body: JSONSerialization.data(withJSONObject: fields, options: .sortedKeys), createdAt: .now
        )
        try await outbox.enqueue(item)
        await refresh()
        return id
    }

    func isQueued(_ kind: PROutboxJob.Kind, about ref: PullRequestRef) -> Bool {
        items.contains { $0.rejection == nil && $0.lane == Self.lane(ref) && Self.kind(of: $0) == kind }
    }

    /// Disconnect, sign out, or another person signing in: nothing saved goes to the next Worker.
    func forget() async {
        for item in await outbox.snapshot {
            await outbox.cancel(id: item.id)
        }
        await refresh()
    }

    /// One PR's jobs go in order; other PRs' don't wait for them.
    private static func lane(_ ref: PullRequestRef) -> String {
        "\(ref.repo)#\(ref.number)"
    }

    private static func kind(of item: OutboxItem) -> PROutboxJob.Kind {
        item.path.hasSuffix("/ask") ? .question : .write
    }

    private nonisolated static func attempt(
        _ item: OutboxItem, client: PRViewerClient, transport: any HTTPTransport
    ) async -> OutboxVerdict {
        do {
            let request = try await client.outboxRequest(path: item.path, body: item.body)
            let (data, response) = try await transport.send(request)
            // A captive portal answers 200 with a page: only JSON is the Worker's answer.
            return .of(
                data: data, response: response,
                isValid: { (try? JSONSerialization.jsonObject(with: $0)) != nil },
                rejection: PRViewerClient.refusal
            )
        } catch {
            return .of(error: error)
        }
    }

    private func accepted(_ item: OutboxItem, _ data: Data) {
        kit?.outboxAnswered(id: item.id, data: data)
    }

    /// A refusal is told once, then dropped: PRHub has no list of waiting jobs to retry it from, and PRKit's toast
    /// gives the words back to the box.
    private func rejected(_ item: OutboxItem, _ reason: String) async {
        kit?.outboxRefused(id: item.id, kind: Self.kind(of: item), reason: reason)
        await outbox.cancel(id: item.id)
    }

    /// The newest state only: announcements can arrive out of order.
    private func refresh() async {
        let state = await outbox.state
        guard state.revision > revision else {
            return
        }
        revision = state.revision
        items = state.items
    }
}
