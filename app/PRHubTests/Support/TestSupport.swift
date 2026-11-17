import Foundation
import Synchronization

/// A value the closures of one test share.
public final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    public init(_ value: Value) {
        state = Mutex(value)
    }

    @discardableResult
    public func with<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        state.withLock { body(&$0) }
    }
}

/// A Worker that answers each request with the next scripted answer, and keeps what it was sent.
public final class StubWorker: Sendable {
    public enum Answer: Sendable {
        case reply(status: Int, body: String)
        case fail(URLError.Code)
    }

    private let answers: Shared<[Answer]>
    public let requests = Shared<[URLRequest]>([])

    public init(_ answers: [Answer]) {
        self.answers = Shared(answers)
    }

    public func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
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
