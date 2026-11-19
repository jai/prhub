import Foundation
@testable import PRHubCore
import PRHubTestSupport
import PRKitCore
import Testing

/// The battery soak's MetricKit reports (`PRHubMetricReports`) on disk: what waits, and what was sent, outlive a relaunch.
@MainActor
struct PRHubMetricKitTests {
    private let resources = IntegrationResources()
    private static let payload = Data(#"{"timeStampBegin":"2026-11-15 00:00:00 +0000","cpuMetrics":{}}"#.utf8)

    private func makeReports(
        failing: Shared<(any Error)?> = Shared(nil), sent: Shared<[PRHubMetricReport]> = Shared([]),
        defaults: UserDefaults? = nil, directory: URL? = nil
    ) -> PRHubMetricReports {
        let directory = directory ?? resources.directory()
        return PRHubMetricReports(
            store: PRDiskFileStore(directory: directory), defaults: defaults ?? resources.defaults(), build: "1.0 (301)",
            os: "iOS 27.2", device: "iPhone13,3"
        ) { report in
            if let error = failing.with({ $0 }) {
                throw error
            }
            sent.with { $0.append(report) }
        }
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
}
