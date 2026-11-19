import CryptoKit
import Foundation
import PRKitCore
#if os(iOS)
    import MetricKit
#endif

/// One MetricKit payload on its way to the Worker's `POST /device/metrics` (docs/api.md, "MetricKit reports").
struct PRHubMetricReport: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metric, diagnostic
    }

    let kind: Kind
    /// MetricKit's `jsonRepresentation()`, as text.
    let payload: String
    let build: String
    let os: String
    let device: String
}

/// The battery soak's reports: each MetricKit payload iOS hands PRHub is saved to `store` (a folder on disk) at once and sent when the Worker
/// asks for them (`metrickit` in `GET /device/config`). A payload sent once is not sent again, one the Worker refuses
/// for good is dropped, and one that could not go waits for the next try. While off, nothing is kept or sent.
@MainActor
final class PRHubMetricReports {
    typealias Send = @Sendable (PRHubMetricReport) async throws -> Void

    static let sentKey = "metricKitSent"
    /// Hashes of the payloads sent, newest last: more than iOS's week of past payloads.
    static let sentKept = 200
    /// What waits at most; the oldest goes first. Two a day, at most a few weeks offline.
    static let waitingMax = 60

    private let store: any PRFileStore
    private let defaults: any PRKeyValueStore
    private let send: Send
    private let build: String
    private let os: String
    private let device: String
    private(set) var isOn = false
    private var isSending = false

    init(
        store: any PRFileStore, defaults: any PRKeyValueStore, build: String = AppIdentity.appVersion(),
        os: String = ProcessInfo.processInfo.operatingSystemVersionString, device: String = PRHubMetricReports.deviceModel(),
        send: @escaping Send
    ) {
        self.store = store
        self.defaults = defaults
        self.build = build
        self.os = os
        self.device = device
        self.send = send
    }

    /// As the Worker's config says. Off forgets what waits.
    func set(isOn: Bool) {
        self.isOn = isOn
        if !isOn {
            store.removeAll()
        }
    }

    /// A payload's JSON, kept until it is sent. Ignored while off and once sent.
    func keep(_ kind: PRHubMetricReport.Kind, json: Data) {
        let hash = Self.hash(json)
        guard isOn, !sent.contains(hash), let payload = String(data: json, encoding: .utf8) else {
            return
        }
        let report = PRHubMetricReport(kind: kind, payload: payload, build: build, os: os, device: device)
        do {
            try store.write(JSONEncoder().encode(report), to: "\(hash).json")
        } catch {
            return
        }
        for file in waiting().dropLast(Self.waitingMax) {
            store.remove(file)
        }
    }

    /// Sends what waits, oldest first. The first failure that may pass (offline, a 5xx) stops it until the next try.
    func flush() async {
        guard isOn, !isSending else {
            return
        }
        isSending = true
        defer { isSending = false }
        for file in waiting() {
            guard isOn else {
                return
            }
            guard let report = store.read(file).flatMap({
                try? JSONDecoder().decode(PRHubMetricReport.self, from: $0)
            }) else {
                store.remove(file)
                continue
            }
            do {
                try await send(report)
            } catch {
                guard (error as? PRWorkerError)?.isPermanent == true else {
                    return
                }
            }
            markSent(String(file.dropLast(".json".count)))
            store.remove(file)
        }
    }

    /// The names of the reports waiting, oldest first.
    func waiting() -> [String] {
        let written = { [store] (name: String) in store.modified(name) ?? .distantPast }
        return store.names().filter { $0.hasSuffix(".json") }
            .sorted { (written($0), $0) < (written($1), $1) }
    }

    private var sent: [String] {
        defaults.stringArray(forKey: Self.sentKey) ?? []
    }

    private func markSent(_ hash: String) {
        defaults.set(Array((sent.filter { $0 != hash } + [hash]).suffix(Self.sentKept)), forKey: Self.sentKey)
    }

    static func hash(_ json: Data) -> String {
        SHA256.hash(data: json).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `iPhone13,3`: what MetricKit's own `deviceType` says, before the payload is opened.
    nonisolated static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

#if os(iOS)
    /// MetricKit's side: subscribes while the reports are on, and hands each payload to `PRHubMetricReports`, the ones iOS
    /// still holds from the past week too (each sent once).
    @MainActor
    final class PRHubMetricKit {
        let reports: PRHubMetricReports
        private var subscriber: Subscriber?

        init(reports: PRHubMetricReports) {
            self.reports = reports
        }

        func update(isOn: Bool) {
            reports.set(isOn: isOn)
            if isOn, subscriber == nil {
                let subscriber = Subscriber(reports: reports)
                self.subscriber = subscriber
                MXMetricManager.shared.add(subscriber)
                for json in MXMetricManager.shared.pastPayloads.map({ $0.jsonRepresentation() }) {
                    reports.keep(.metric, json: json)
                }
                for json in MXMetricManager.shared.pastDiagnosticPayloads.map({ $0.jsonRepresentation() }) {
                    reports.keep(.diagnostic, json: json)
                }
            } else if !isOn, let subscriber {
                MXMetricManager.shared.remove(subscriber)
                self.subscriber = nil
            }
        }

        func flush() async {
            await reports.flush()
        }

        /// MetricKit calls it on a queue of its own; the payloads become JSON there, and are kept on the main actor.
        private final class Subscriber: NSObject, MXMetricManagerSubscriber, Sendable {
            let reports: PRHubMetricReports

            init(reports: PRHubMetricReports) {
                self.reports = reports
            }

            func didReceive(_ payloads: [MXMetricPayload]) {
                hand(.metric, payloads.map { $0.jsonRepresentation() })
            }

            func didReceive(_ payloads: [MXDiagnosticPayload]) {
                hand(.diagnostic, payloads.map { $0.jsonRepresentation() })
            }

            private func hand(_ kind: PRHubMetricReport.Kind, _ jsons: [Data]) {
                let reports = reports
                Task { @MainActor in
                    for json in jsons {
                        reports.keep(kind, json: json)
                    }
                    await reports.flush()
                }
            }
        }
    }
#endif
