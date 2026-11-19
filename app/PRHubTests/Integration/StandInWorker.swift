import DurableNetworking
import Foundation
@testable import PRKit

/// A Worker for integration tests, answering the routes the PR screens read from the sample PRs' files in `staging`.
/// A write is refused: nothing here posts. Offline, every request fails as with no network.
struct StandInWorker: HTTPTransport {
    static let url = URL(string: "https://stub-worker.invalid")!

    let samples: PRSampleSet
    let staging: URL
    let isOffline: Bool

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isOffline {
            throw URLError(.notConnectedToInternet)
        }
        let url = request.url ?? Self.url
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
