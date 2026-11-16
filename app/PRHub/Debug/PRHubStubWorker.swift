#if DEBUG
    import DurableNetworking
    import Foundation
    import PRKit

    /// Debug builds only. `-PRHubStubWorker`: a paired PRHub whose Worker is a stand-in in the app, answering from the
    /// sample PRs, with the real mirror and kept reads behind it, so a UI test can load everything online and then open it
    /// again with no network (issue #52). With `-PRHubOffline` every request fails as with no network and the device counts
    /// as offline; with `-PRHubStubWorkerFresh` the mirror, the kept reads and the list's settings start empty.
    enum PRHubStubWorker {
        static let worker = URL(string: "https://stub-worker.invalid")!

        @MainActor static func environment(_ arguments: [String]) -> PRHubEnvironment {
            let offline = arguments.contains("-PRHubOffline")
            let mirror = PRHubPRHost.mirrorDirectory()
            if arguments.contains("-PRHubStubWorkerFresh") {
                try? FileManager.default.removeItem(at: mirror)
                PRSampleSet.resetListSettings()
            }
            let staging = URL.temporaryDirectory.appending(path: "prhub-stub-worker", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let samples = PRSampleSet.prHub
            // Into the stand-in's own folder, keeping the list's settings: seeding resets them.
            let settings = PRSampleSet.listSettingKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            _ = samples.seed(in: staging)
            for (key, value) in settings {
                UserDefaults.standard.set(value, forKey: key)
            }
            let transport = Transport(samples: samples, staging: staging, isOffline: offline)
            let access = PRViewerAccess(baseURL: { worker }, bearer: { "stub" }, discard: {})
            let environment = PRHubEnvironment.offline(
                config: DeviceConfig(features: [.askAI, .keyLines], login: PRSampleSet.prHubLogin), access: access,
                worker: worker, defaultsSuite: "stub-worker", isSample: false, transport: transport
            )
            if offline {
                environment.prs.network.holdOffline()
            }
            return environment
        }

        /// The Worker's routes the PR screens read, from the samples. A write is refused: nothing here posts.
        struct Transport: HTTPTransport {
            let samples: PRSampleSet
            let staging: URL
            let isOffline: Bool

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if isOffline {
                    throw URLError(.notConnectedToInternet)
                }
                let url = request.url ?? worker
                let (status, body) = answer(path: url.path(), query: url.query() ?? "")
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                )
                return (body, response ?? HTTPURLResponse())
            }

            private func answer(path: String, query: String) -> (Int, Data) {
                let parts = path.split(separator: "/").map(String.init)
                if parts == ["prs"] {
                    return (200, json(["prs": encoded(samples.rows), "synced_at": Date.now.timeIntervalSince1970 * 1000]))
                }
                if parts == ["prs", "merged"] {
                    return (200, json(["prs": encoded(samples.merged(reviewed: query.contains("of=reviewed")))]))
                }
                guard parts.count == 5, parts[0] == "prs", let number = Int(parts[3]),
                      let row = samples.rows.first(where: { $0.repo == "\(parts[1])/\(parts[2])" && $0.number == number })
                else {
                    return (404, json(["error": "Not in the stand-in Worker"]))
                }
                switch parts[4] {
                case "detail": return file(row.detailFileName)
                case "diff": return file(row.diffFileName)
                case "key-lines":
                    return samples.keyLines(for: PullRequestRef(repo: row.repo, number: row.number)).map { (200, $0) }
                        ?? (404, json(["error": "No key lines"]))
                case "ask": return (200, json(["messages": [Any](), "isWorking": false]))
                case "key-lines-reviewed": return (200, json(["lines": [Any]()]))
                default: return (403, json(["error": "The stand-in Worker posts nothing"]))
                }
            }

            private func file(_ name: String) -> (Int, Data) {
                (try? Data(contentsOf: staging.appending(path: name))).map { (200, $0) }
                    ?? (404, json(["error": "Not in the stand-in Worker"]))
            }

            private func encoded(_ rows: [PullRequestRow]) -> Any {
                (try? JSONEncoder().encode(rows)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [Any]()
            }

            private func json(_ object: [String: Any]) -> Data {
                (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            }
        }
    }
#endif
