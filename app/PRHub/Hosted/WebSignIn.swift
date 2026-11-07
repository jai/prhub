import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#endif

/// The app's `Authenticate`: `ASWebAuthenticationSession` on `/auth/github/start`, catching the HTTPS callback
/// `https://<worker host>/auth/github/done`. Only an app with `webcredentials:<host>` in its associated domains may catch
/// it (app/Config/PRHub.xcconfig), so no other app can take the code. Not ephemeral: someone signed in to github.com in
/// Safari only has to authorize PRHub.
@MainActor
enum WebSignIn {
    static let live: Authenticate = { start, host in
        try await authenticate(start: start, host: host)
    }

    private static func authenticate(start: URL, host: String) async throws -> URL {
        let anchor = PresentationAnchor()
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: start, callback: .https(host: host, path: SignInAttempt.callbackPath)
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(throwing: SignInError.sessionUnavailable)
                }
            }
            session.presentationContextProvider = anchor
            if !session.start() {
                continuation.resume(throwing: SignInError.sessionUnavailable)
            }
        }
        withExtendedLifetime(anchor) {}
        return url
    }

    /// The key window the sheet rises from.
    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                #if os(iOS)
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
                #else
                return ASPresentationAnchor()
                #endif
            }
        }
    }
}
