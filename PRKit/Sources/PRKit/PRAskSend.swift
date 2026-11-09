import Foundation
import Network
import PRKitCore

/// What became of a question handed to the model (`PRsModel.ask`).
enum PRAskOutcome: Equatable {
    /// The Worker has it: the chat as it now stands, the question in it.
    case answered(PRAskChat)
    /// The host's outbox holds it and goes on sending it; the Worker hasn't answered yet.
    case queued
}

/// A question to the PR's AI between the send and the chat having it: what the Ask sheet says under it. Its own state,
/// not a write's: nothing goes to GitHub, and a slow answer is not an error.
enum PRAskSend: Equatable {
    case idle
    /// On its way, to the Worker or in the outbox while the phone is online. Quiet.
    case sending(PRAskQuestion)
    /// In the outbox while the phone is offline: it goes by itself when the network is back.
    case waitingForNetwork(PRAskQuestion)
    /// It could not go. Try again sends it again.
    case failed(PRAskQuestion, reason: String)

    var question: PRAskQuestion? {
        switch self {
        case .idle: nil
        case let .sending(question), let .waitingForNetwork(question), let .failed(question, _): question
        }
    }

    /// Still going by itself: the sheet keeps following it.
    var isOnItsWay: Bool {
        switch self {
        case .sending, .waitingForNetwork: true
        case .idle, .failed: false
        }
    }

    /// Where a send stands once the model has answered, or thrown.
    static func after(_ outcome: Result<PRAskOutcome, any Error>, of question: PRAskQuestion, isOnline: Bool) -> PRAskSend {
        switch outcome {
        case .success(.answered): .idle
        case .success(.queued): isOnline ? .sending(question) : .waitingForNetwork(question)
        case let .failure(error): .failed(question, reason: error.localizedDescription)
        }
    }

    /// A question left in the outbox, as the sheet follows it: gone from the outbox means the Worker has it, and the
    /// network decides which quiet words it shows meanwhile.
    func following(isQueued: Bool, isOnline: Bool) -> PRAskSend {
        guard isOnItsWay, let question else {
            return self
        }
        guard isQueued else {
            return .idle
        }
        return isOnline ? .sending(question) : .waitingForNetwork(question)
    }
}

/// Whether the device has a network now, from the system's own path monitor: one for the process.
final class PRNetworkPath: @unchecked Sendable {
    static let shared = PRNetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            lock.withLock { satisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "PRKit.network-path"))
    }

    var isOnline: Bool {
        lock.withLock { satisfied }
    }
}
