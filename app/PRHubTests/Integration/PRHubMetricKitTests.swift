import Foundation
@testable import PRHubCore
import PRHubTestSupport
import PRKitCore
import Testing

/// The battery soak's MetricKit reports (`PRHubMetricReports`): kept on disk until sent, sent once, and nothing while off.
@MainActor
struct PRHubMetricKitTests {
    private let resources = IntegrationResources()
    private static let payload = Data(#"{"timeStampBegin":"2026-11-15 00:00:00 +0000","cpuMetrics":{}}"#.utf8)

    private func makeReports(
        failing: Shared<(any Error)?> = Shared(nil), sent: Shared<[PRHubMetricReport]> = Shared([]),
        defaults: UserDefaults? = nil, directory: URL? = nil
    ) -> PRHubMetricReports {
        let directory = directory ?? resources.directory()
        return PRHubMetricReports(directory: directory, defaults: defaults ?? resources.defaults(), build: "1.0 (301)", os: "iOS 27.2",
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
        let reports = makeReports(sent: sent)
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

    @Test func queuedPayloadsSurviveRelaunchAndSentPayloadsStayDeduplicated() async {
        let directory = resources.directory()
        let defaults = resources.defaults()
        let sent = Shared<[PRHubMetricReport]>([])
        let first = makeReports(sent: sent, defaults: defaults, directory: directory)
        first.set(isOn: true)
        first.keep(.metric, json: Self.payload)
        #expect(first.waiting().count == 1)

        let relaunched = makeReports(sent: sent, defaults: defaults, directory: directory)
        relaunched.set(isOn: true)
        #expect(relaunched.waiting().count == 1)
        await relaunched.flush()
        #expect(sent.with { $0.count } == 1)
        #expect(relaunched.waiting().isEmpty)

        let afterDelivery = makeReports(sent: sent, defaults: defaults, directory: directory)
        afterDelivery.set(isOn: true)
        afterDelivery.keep(.metric, json: Self.payload)
        await afterDelivery.flush()
        #expect(sent.with { $0.count } == 1)
        #expect(afterDelivery.waiting().isEmpty)
    }

    @Test func offKeepsAndSendsNothing() async {
        let sent = Shared<[PRHubMetricReport]>([])
        let reports = makeReports(sent: sent)
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
        let reports = makeReports(failing: failing, sent: sent)
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
        let reports = makeReports()
        reports.set(isOn: true)
        for index in 0 ..< (PRHubMetricReports.waitingMax + 5) {
            reports.keep(.metric, json: Data(#"{"n":\#(index)}"#.utf8))
        }
        #expect(reports.waiting().count == PRHubMetricReports.waitingMax)
    }
}
