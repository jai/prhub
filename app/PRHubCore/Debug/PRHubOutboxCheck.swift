#if DEBUG
    import DurableNetworking
    import Foundation
    import Observation
    import PRKit

    /// The real outbox and PR screens over an in-app Worker. Only this fixture accepts its up/down control links.
    public enum PRHubOutboxCheck {
        @MainActor public static let control = Control()
        private static let worker = URL(string: "https://outbox-check.invalid")!

        @MainActor static func environment(_ resources: PRHubUITestResources) -> PRHubEnvironment {
            let directory = resources.directory
            let defaults = resources.defaults
            let mirror = directory.appending(path: "mirror")
            try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
            let samples = PRSampleSet.prHub
            let rows = samples.seed(in: mirror, defaults: defaults)
            try? JSONEncoder().encode(rows).write(to: mirror.appending(path: "rows.json"))
            let transport = Transport(samples: samples, staging: mirror)
            control.transport = transport
            let access = PRViewerAccess(baseURL: { worker }, bearer: { "outbox-check" }, discard: {})
            var backoff = OutboxBackoff()
            backoff.base = .milliseconds(100)
            backoff.cap = .milliseconds(100)
            backoff.floor = .milliseconds(100)
            backoff.random = { 1 }
            let outbox = PRHubOutbox(
                client: PRViewerClient(access: access, transport: transport),
                file: directory.appending(path: "outbox.json"), send: transport, backoff: backoff
            )
            let environment = PRHubEnvironment.offline(
                config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), access: access, worker: worker,
                isSample: false, usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults), outbox: outbox,
                transport: transport, storage: resources.storage(), build: .current,
                alertPermission: resources.alertPermission(), network: PRNetwork(isOnline: true)
            )
            resources.isolateAlerts(in: environment)
            outbox.kit = environment.prs
            // Short, so the test sees each job outlast its screen's wait without sitting through 15 seconds.
            environment.prs.answerWait = .seconds(1)
            outbox.start(watchingNetwork: false)
            return environment
        }

        @MainActor
        @Observable
        public final class Control {
            public private(set) var status = "up"
            @ObservationIgnored fileprivate var transport: Transport?

            public func open(_ url: URL) -> Bool {
                guard let transport, url.scheme == "prhub-pr", url.host() == "ui-test-outbox",
                      let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                          .first(where: { $0.name == "state" })?.value, ["up", "down"].contains(state)
                else {
                    return false
                }
                Task {
                    await transport.setOffline(state == "down")
                    status = state
                }
                return true
            }
        }

        fileprivate actor Transport: HTTPTransport {
            private let samples: PRSampleSet
            private let reads: PRHubStubWorker.Transport
            private var offline = false
            private var details: [String: Data] = [:]
            private var chats: [String: Data] = [:]

            init(samples: PRSampleSet, staging: URL) {
                self.samples = samples
                reads = PRHubStubWorker.Transport(samples: samples, staging: staging, isOffline: false)
            }

            func setOffline(_ value: Bool) {
                offline = value
            }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard !offline else { throw URLError(.notConnectedToInternet) }
                let url = request.url ?? worker
                let path = url.path().split(separator: "/").map(String.init)
                guard path.count == 5, path[0] == "prs", let number = Int(path[3]),
                      let sample = samples.samples.first(where: { $0.row.repo == "\(path[1])/\(path[2])" && $0.row.number == number })
                else {
                    return try await reads.send(request)
                }
                let key = "\(sample.row.repo)#\(number)"
                if request.httpMethod == "POST" {
                    let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
                    if path[4] == "ask" {
                        let question = payload["question"] as? String ?? ""
                        let chat: [String: Any] = [
                            "messages": [
                                ["id": "question-1", "role": "you", "text": question],
                                ["id": "answer-1", "role": "agent", "text": "The stand-in Worker received your question."],
                            ],
                            "isWorking": false,
                        ]
                        let data = try JSONSerialization.data(withJSONObject: chat)
                        chats[key] = data
                        return response(data, to: url)
                    }
                    if path[4] == "write" {
                        return write(payload, sample: sample, key: key, url: url)
                    }
                }
                if path[4] == "detail", let data = details[key] {
                    return response(data, to: url)
                }
                if path[4] == "ask", let data = chats[key] {
                    return response(data, to: url)
                }
                return try await reads.send(request)
            }

            private func write(
                _ payload: [String: Any], sample: PRSampleSet.Sample, key: String, url: URL
            ) -> (Data, HTTPURLResponse) {
                let body = payload["body"] as? String ?? ""
                if body.contains("Please refuse this") {
                    return response(Data(#"{"error":"The stand-in Worker refused this comment."}"#.utf8), to: url, status: 422)
                }
                let write: PRWrite
                switch payload["kind"] as? String {
                case "comment": write = .comment(body: body)
                case "review":
                    write = .review(
                        PRReviewEvent(rawValue: payload["event"] as? String ?? "") ?? .approve,
                        body: body, commit: payload["commit"] as? String ?? "", comments: []
                    )
                default:
                    return response(Data(#"{"error":"Unsupported fixture write"}"#.utf8), to: url, status: 422)
                }
                let data = PRSampleSet.applying(
                    write, to: details[key] ?? Data(sample.detail.utf8), login: PRSampleSet.prHubLogin
                )
                details[key] = data
                return response(data, to: url)
            }

            private func response(_ data: Data, to url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
                (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!)
            }
        }
    }
#endif
