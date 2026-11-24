import Foundation

/// Registers this phone with FeedbackKit for its chats' pushes (`POST /v2/devices`, jai/feedbackkit docs/api.md
/// "Pushes"). FeedbackKit pushes only to the devices registered with it, and PRHub gave its APNs token to the pr-worker
/// alone, so an agent's answer in a feedback chat never reached the phone. The token and FeedbackKit's direct path
/// arrive in either order; the first moment both are known sends, and a send that failed goes again when the app next
/// comes forward. Only the direct path can register: FeedbackKit takes a device with the sender's own token.
public actor PRHubFeedbackDevices {
    typealias Send = @Sendable (_ token: String) async throws -> Void

    private var token: String?
    private var register: Send?
    private var unregister: Send?
    /// The token FeedbackKit has taken on this path.
    private var registered: String?

    public init() {}

    /// The system gave the APNs token, in hex.
    public func tokenArrived(_ token: String) async {
        self.token = token
        await send()
    }

    /// Feedback is on FeedbackKit's direct path: `register` is its `POST /v2/devices`, `unregister` its `DELETE`.
    func connected(register: @escaping Send, unregister: @escaping Send) async {
        self.register = register
        self.unregister = unregister
        registered = nil
        await send()
    }

    /// Feedback left the direct path: nothing to register with.
    func disconnected() {
        register = nil
        unregister = nil
        registered = nil
    }

    /// The app came forward: a registration that failed goes again; one that went through sends nothing.
    public func retry() async {
        await send()
    }

    /// The account is leaving: FeedbackKit stops pushing its chats here. Best effort; a failure is not retried.
    func forget() async {
        guard let unregister, let registered else {
            return
        }
        self.registered = nil
        try? await unregister(registered)
    }

    private func send() async {
        guard let token, let register, registered != token else {
            return
        }
        do {
            try await register(token)
            registered = token
        } catch {
            // Again at the next foreground (`retry`).
        }
    }
}
