import Foundation

/// Sends the PR screens' requests: 15 s a request, and, while someone is looking at the app, a request made with no
/// network waits for one, up to two minutes, so an elevator delays it and doesn't fail it. Nothing here repeats a
/// request: a review or a comment must not land twice. Package-only, so an app's own network types keep their names.
package struct PRTransport: Sendable {
    /// For a background wake, which has a budget: 15 s a request.
    private let quick: URLSession
    /// In the app: waits for a network.
    private let waiting: URLSession
    private let isInForeground: @Sendable () async -> Bool

    private static let waitLimit: TimeInterval = 120

    private static func makeSession(waits: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral // Nothing to cache, and no cookies.
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = waits
        if waits {
            configuration.timeoutIntervalForResource = waitLimit
            configuration.networkServiceType = .responsiveData
        }
        return URLSession(configuration: configuration)
    }

    package init(isInForeground: @escaping @Sendable () async -> Bool) {
        quick = Self.makeSession(waits: false)
        waiting = Self.makeSession(waits: true)
        self.isInForeground = isInForeground
    }

    /// The session for a request starting now.
    package func session() async -> URLSession {
        await isInForeground() ? waiting : quick
    }

    /// The Workers run on Cloudflare, which answers HTTP/3: its connections move between Wi-Fi and cellular, where a
    /// TCP one breaks. The system still falls back to HTTP/2.
    package static func preferringHTTP3(_ request: URLRequest) -> URLRequest {
        var request = request
        request.assumesHTTP3Capable = true
        return request
    }
}
