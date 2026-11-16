import Foundation
import Synchronization

/// The worker's golden fixtures (docs/fixtures/), read where they are in the repo: `swift test` runs from the sources.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../docs/fixtures", directoryHint: .isDirectory)
        return try Data(contentsOf: fixtures.appending(path: name))
    }
}

/// A value the closures of one test share.
final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    @discardableResult
    func with<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        state.withLock { body(&$0) }
    }
}

/// A Worker that answers each request with the next scripted answer, and keeps what it was sent.
final class StubWorker: Sendable {
    enum Answer: Sendable {
        case reply(status: Int, body: String)
        case fail(URLError.Code)
    }

    private let answers: Shared<[Answer]>
    let requests = Shared<[URLRequest]>([])

    init(_ answers: [Answer]) {
        self.answers = Shared(answers)
    }

    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.with { $0.append(request) }
        let answer = answers.with { $0.isEmpty ? Answer.fail(.timedOut) : $0.removeFirst() }
        switch answer {
        case let .reply(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case let .fail(code):
            throw URLError(code)
        }
    }
}
