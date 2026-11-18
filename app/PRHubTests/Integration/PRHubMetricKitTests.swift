import Foundation
@testable import PRHubCore
import PRHubTestSupport
import PRKitCore
import Testing

/// The battery soak's MetricKit reports (`PRHubMetricReports`): kept on disk until sent, sent once, and nothing while off.
@MainActor
struct PRHubMetricKitTests {
    private static let payload = Data(#"{"timeStampBegin":"2026-11-15 00:00:00 +0000","cpuMetrics":{}}"#.utf8)

    private static func reports(
        failing: Shared<(any Error)?> = Shared(nil), sent: Shared<[PRHubMetricReport]> = Shared([]),
        defaults: UserDefaults = UserDefaults(suiteName: "prhub-metrickit-\(UUID().uuidString)")!
    ) -> PRHubMetricReports {
        let directory = FileManager.default.temporaryDirectory.appending(path: "metrickit-\(UUID().uuidString)")
        return PRHubMetricReports(directory: directory, defaults: defaults, build: "1.0 (301)", os: "iOS 27.2",
                                  device: "iPhone13,3")
        { report in
            if let error = failing.with({ $0 }) {
                throw error
            }
            sent.with { $0.append(report) }
        }
    }

    @Test func aPayloadIsSentOnceWithTheBuildAndDevice() async {
        let sent = Shared<[PRHubMetricReport]>([])
        let reports = Self.reports(sent: sent)
        reports.set(isOn: true)
        reports.keep(.metric, json: Self.payload)
        await reports.flush()
        reports.keep(.metric, json: Self.payload)
        await reports.flush()
        let got = sent.with { $0 }
        #expect(got == [PRHubMetricReport(kind: .metric, payload: String(decoding: Self.payload, as: UTF8.self),
                                          build: "1.0 (301)", os: "iOS 27.2", device: "iPhone13,3")])
        #expect(reports.waiting().isEmpty)
    }

    @Test func offKeepsAndSendsNothing() async {
        let sent = Shared<[PRHubMetricReport]>([])
        let reports = Self.reports(sent: sent)
        reports.keep(.metric, json: Self.payload)
        await reports.flush()
        #expect(reports.waiting().isEmpty)
        reports.set(isOn: true)
        reports.keep(.diagnostic, json: Self.payload)
        reports.set(isOn: false)
        #expect(reports.waiting().isEmpty, "turning it off forgets what waits")
        #expect(sent.with { $0 }.isEmpty)
    }

    @Test func aPassingFailureWaitsAndAPermanentOneIsDropped() async {
        let failing = Shared<(any Error)?>(URLError(.notConnectedToInternet))
        let sent = Shared<[PRHubMetricReport]>([])
        let reports = Self.reports(failing: failing, sent: sent)
        reports.set(isOn: true)
        reports.keep(.metric, json: Self.payload)
        await reports.flush()
        #expect(reports.waiting().count == 1, "offline: it waits for the next try")
        failing.with { $0 = nil }
        await reports.flush()
        #expect(sent.with { $0 }.count == 1)

        failing.with { $0 = PRWorkerError(status: 404) }
        reports.keep(.diagnostic, json: Data(#"{"other":1}"#.utf8))
        await reports.flush()
        #expect(reports.waiting().isEmpty, "a Worker with reports off says so for good")
    }

    @Test func atMostSixtyWait() {
        let reports = Self.reports()
        reports.set(isOn: true)
        for index in 0 ..< (PRHubMetricReports.waitingMax + 5) {
            reports.keep(.metric, json: Data(#"{"n":\#(index)}"#.utf8))
        }
        #expect(reports.waiting().count == PRHubMetricReports.waitingMax)
    }
}
