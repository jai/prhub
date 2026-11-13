import Foundation
import Synchronization
import Testing
@testable import PRKitCore

/// A failed request to the Worker: what it was for, how it failed, the words it shows, and one report per failure.
struct PRRequestFailureTests {
    @Test(arguments: [
        ("prs", PRRequestArea.prs), ("prs/merged", .prs), ("prs/acme/api/7/detail", .detail),
        ("prs/acme/api/7/diff", .diff), ("prs/acme/api/7/ask", .ask), ("prs/acme/api/7/write", .write),
        ("prs/acme/api/7/key-lines", .keyLines), ("prs/acme/api/7/key-lines-reviewed", .keyLines),
        ("prs/acme/api/7/rewrite", .rewrite), ("prs/acme/api/7/summary", .summary), ("repos", .repos),
        ("feedback", .feedback), ("feedback/fb_0123456789abcdef", .feedback), ("device/config", .config),
        ("device/register", .device), ("events", .other), ("prs/acme/api/7", .other),
    ])
    func aRouteNamesItsArea(path: String, area: PRRequestArea) {
        #expect(PRRequestArea(path: path) == area)
    }

    @Test func aConnectionsFailureIsOfflineTimeoutOrNetworkAndACancelIsNone() {
        #expect(PRRequestFailure(transport: URLError(.notConnectedToInternet)) == .offline)
        #expect(PRRequestFailure(transport: URLError(.cannotFindHost)) == .offline)
        #expect(PRRequestFailure(transport: URLError(.timedOut)) == .timeout)
        #expect(PRRequestFailure(transport: URLError(.secureConnectionFailed)) == .network)
        #expect(PRRequestFailure(transport: URLError(.cancelled)) == nil)
        #expect(PRRequestFailure(transport: CancellationError()) == nil)
    }

    /// A 404 off a PR's route, such as Cloudflare refusing one Worker's fetch of another, isn't a missing PR.
    @Test func aNotFoundSpeaksOfWhatWasAskedFor() {
        let page = Data("<html>error code: 1042</html>".utf8)
        #expect(PRWorkerError(status: 404, body: page, area: .detail) == .notFound)
        #expect(PRWorkerError(status: 404, body: page, area: .feedback).localizedDescription
            == "Feedback can't be reached. Try again.")
        #expect(PRWorkerError(status: 404, body: page, area: .config) == .unreachable(.config))
        #expect(!PRWorkerError.unreachable(.feedback).isPermanent)
        let words = Data(#"{"error": "Not found."}"#.utf8)
        #expect(PRWorkerError(status: 404, body: words, area: .feedback) == .refused("Not found.", isPermanent: true))
    }

    final class Reports: Sendable {
        let seen = Mutex<[String]>([])
        func add(_ area: PRRequestArea, _ failure: PRRequestFailure) {
            seen.withLock { $0.append("\(area.rawValue) \(failure)") }
        }
    }

    private func client(
        _ reports: Reports, answer: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> PRViewerClient {
        let access = PRViewerAccess(
            baseURL: { URL(string: "https://worker.example.com")! }, bearer: { "t" }, discard: {}
        )
        return PRViewerClient(access: access, exchange: { try answer($0) }).reporting { reports.add($0, $1) }
    }

    private static func status(_ code: Int, _ body: String = "", for request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    @Test func eachFailureIsReportedOnceAndASecondOfTheSameKindWithinAMinuteIsNot() async {
        let reports = Reports()
        let worker = client(reports) { Self.status(404, "<html></html>", for: $0) }
        _ = try? await worker.read("feedback", as: [String: Int].self)
        _ = try? await worker.read("feedback", as: [String: Int].self)
        _ = try? await worker.read("device/config", as: [String: Int].self)
        #expect(reports.seen.withLock { $0 } == ["feedback status(404)", "config status(404)"])
    }

    @Test func offlineAndAnUnreadableAnswerAreReportedAndASuccessOrACancelIsNot() async {
        let reports = Reports()
        let offline = client(reports) { _ in throw URLError(.notConnectedToInternet) }
        _ = try? await offline.pullRequests()
        let cancelled = client(reports) { _ in throw URLError(.cancelled) }
        _ = try? await cancelled.pullRequests()
        let garbled = client(reports) { Self.status(200, "not json", for: $0) }
        _ = try? await garbled.askChat(PullRequestRef(repo: "acme/api", number: 7))
        let fine = client(reports) { Self.status(200, #"{"prs": [], "synced_at": 1}"#, for: $0) }
        _ = try? await fine.pullRequests()
        #expect(reports.seen.withLock { $0 } == ["prs offline", "ask unreadable"])
    }

    @Test func aRepeatOfTheSameFailureIsReportedAgainAfterAMinute() {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let reports = Reports()
        let reporter = PRFailureReporter(now: { clock.withLock { $0 } }, report: { reports.add($0, $1) })
        reporter.failed(.diff, .timeout)
        clock.withLock { $0 += 30 }
        reporter.failed(.diff, .timeout)
        clock.withLock { $0 += 31 }
        reporter.failed(.diff, .timeout)
        #expect(reports.seen.withLock { $0 } == ["diff timeout", "diff timeout"])
    }
}
