import SwiftUI

/// Sign in again: the hosted Worker says GitHub no longer honours this person's tokens (`account.state` `signed_out`, a
/// `401 signed_out`, or the `signed_out` push). Why, in one line; Sign in with GitHub, whose status arrives under it;
/// and Sign out, which forgets the account on this phone. The PRs stay on the phone until one of the two.
struct SignedOutView: View {
    let environment: PRHubEnvironment
    @State private var signingOut = false

    private var connection: WorkerConnection { environment.connection }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                PageHeader(
                    title: "Sign in to GitHub again", message: Self.words(reason: connection.config?.account?.reason),
                    messageIdentifier: "signedOutReason"
                )

                PRPageBlock {
                    SignInWithGitHubButton(isWorking: connection.phase == .working(.signingIn)) {
                        Task { await environment.signIn() }
                    }
                    if case .signInFailed(let error) = connection.phase, let message = error.message {
                        ProblemLine(message: message)
                            .accessibilityIdentifier("signedOutStatus")
                            .transition(.fold)
                    }
                    if let login = connection.config?.account?.login {
                        Text("Signed in as \(login) until GitHub stopped answering for you.")
                            .font(.appCaption)
                            .foregroundStyle(Color.inkQuiet)
                    }
                }

                PRPageBlock {
                    Text("Signing out forgets your account and its PRs on this phone.")
                        .font(.appFootnote)
                        .foregroundStyle(Color.inkQuiet)
                    Button("Sign out") {
                        signingOut = true
                        Task {
                            await environment.signOut()
                            signingOut = false
                        }
                    }
                    .buttonStyle(PRButtonStyle(.secondary))
                    .disabled(signingOut)
                    .accessibilityIdentifier("signedOutSignOut")
                }
                .padding(.top, Space.xl)
            }
            .padding(.vertical, Space.xl)
            .animation(AppMotion.fold, value: connection.phase)
        }
        .background(Color.groundPage)
        .readableContentWidth()
        .disabled(connection.isWorking)
    }

    /// `account.reason`, as the person would say it.
    static func words(reason: String?) -> String {
        switch reason {
        case "revoked":
            "PRHub's access was removed on GitHub. Sign in to give it back, and your PRs pick up where they left off."
        case "refresh_expired":
            "It's been six months since PRHub last reached GitHub for you, so GitHub asks you to sign in again."
        default:
            "GitHub signed PRHub out. Sign in again to keep your pull requests up to date."
        }
    }
}
