#if DEBUG
import Foundation
import PRKit

/// Debug builds only. `-PRHubOutboxCheck <worker URL>`: the sample PRs, read from a stand-in Worker at that URL, with an
/// outbox in front of it, as Agent Pager has. A write or a question is saved here first and tried every 3 seconds until
/// the Worker answers, so stopping the stand-in shows a job saved and still going, and starting it shows the job land.
/// For checking the outbox's states on a Simulator; PRHub itself has no outbox.
enum PRHubOutboxCheck {
    @MainActor static func environment(worker: URL) -> PRHubEnvironment {
        let directory = PRHubPRHost.mirrorDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows = PRSampleSet.prHub.seed(in: directory)
        try? JSONEncoder().encode(rows).write(to: directory.appending(path: "rows.json"))
        let access = PRViewerAccess(baseURL: { worker }, bearer: { "outbox-check" }, discard: {})
        let outbox = Outbox(client: PRViewerClient(access: access, isInForeground: { true }))
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), access: access, worker: worker,
            defaultsSuite: "outbox-check", isSample: false, outbox: outbox
        )
        outbox.kit = environment.prs
        return environment
    }

    @MainActor
    final class Outbox: PRKitOutbox {
        private struct Item {
            let id: String
            let job: PROutboxJob
            let path: String
            let body: Data
        }

        private let client: PRViewerClient
        weak var kit: PRKitController?
        private var items: [Item] = []
        private var delivering: Task<Void, Never>?

        init(client: PRViewerClient) {
            self.client = client
        }

        func enqueue(_ job: PROutboxJob) async throws -> String {
            let id = UUID().uuidString
            let ref = job.ref
            let (route, encoded) = switch job {
            case let .write(write, _): ("write", try JSONEncoder().encode(write))
            case let .question(question, _): ("ask", try JSONEncoder().encode(question))
            }
            var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            fields["client_ref"] = id
            let body = try JSONSerialization.data(withJSONObject: fields)
            items.append(Item(id: id, job: job, path: "prs/\(ref.repo)/\(ref.number)/\(route)", body: body))
            if delivering == nil {
                delivering = Task { await deliver() }
            }
            return id
        }

        func isQueued(_ kind: PROutboxJob.Kind, about ref: PullRequestRef) -> Bool {
            items.contains { $0.job.kind == kind && $0.job.ref == ref }
        }

        /// In order, each until the Worker answers: a 2xx or 4xx ends it, anything else is tried again.
        private func deliver() async {
            while let item = items.first {
                if let (data, status) = await send(item), status < 500 {
                    items.removeFirst()
                    if (200..<300).contains(status) {
                        kit?.outboxAnswered(id: item.id, data: data)
                    } else {
                        let reason = PRViewerClient.refusal(status: status, body: data)
                        kit?.outboxRefused(id: item.id, kind: item.job.kind, reason: reason)
                    }
                    continue
                }
                try? await Task.sleep(for: .seconds(3))
            }
            delivering = nil
        }

        private func send(_ item: Item) async -> (Data, Int)? {
            guard let request = try? await client.outboxRequest(path: item.path, body: item.body),
                  let (data, response) = try? await URLSession.shared.data(for: request) else {
                return nil
            }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
#endif
