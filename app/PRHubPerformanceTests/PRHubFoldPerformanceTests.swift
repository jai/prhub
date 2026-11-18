import XCTest

/// Physical-device hitch measurements for the folding interaction. This records metrics for comparison; it does not
/// impose a performance budget until a device-specific XCTest baseline is recorded. It is outside the default UI plan.
@MainActor
final class PRHubFoldPerformanceTests: PRHubUITestCase {
    func testFoldingHitches() {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil else {
            XCTFail("XCTHitchMetric requires a physical device; run the performance plan on a device")
            return
        }
        let header = openSecondFilePinned()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            header.tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
            header.tap()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
        }
    }
}
