import Foundation

/// What this build of PRHub offers, from `Config/PRHub.xcconfig` through Info.plist: the hosted Worker, and which ways
/// in onboarding shows. A Debug build also takes each path's flag as a launch argument (`-PRHubSelfHosted YES`), for the
/// UI tests.
struct PRHubBuild: Equatable, Sendable {
    /// The hosted Worker, `https://<PRHUB_HOSTED_HOST>`; nil when the build names none.
    var hostedURL: URL?
    /// Sign in with GitHub, on the hosted Worker.
    var signInWithGitHub: Bool
    /// Connect your own Worker: the setup link, its QR code and the address and code. Off, a setup link says so; a
    /// Worker paired before keeps working.
    var selfHosted: Bool
    /// Try with sample PRs.
    var samples: Bool

    static let current = PRHubBuild(
        info: Bundle.main.infoDictionary ?? [:], overrides: debugOverrides
    )

    /// Where an org owner installs the PRHub GitHub App, or a member asks for it.
    static let appInstallURL = URL(string: "https://github.com/apps/prhub-app/installations/new")!
    /// Opens Settings (`PRHubRootView`), where the hosted Worker takes the person's Anthropic key.
    static let settingsURL = URL(string: "prhub://settings")!

    /// A github.com page where the App is installed or its installation changed: `appInstallURL`, or an installation's
    /// settings (`GitHubInstallation.settingsURL`).
    static func isInstallationPage(_ url: URL) -> Bool {
        url.host() == "github.com" && url.pathComponents.contains("installations")
    }

    init(hostedURL: URL?, signInWithGitHub: Bool, selfHosted: Bool, samples: Bool) {
        self.hostedURL = hostedURL
        self.signInWithGitHub = signInWithGitHub
        self.selfHosted = selfHosted
        self.samples = samples
    }

    /// Info.plist's `PRHubHostedHost`, `PRHubSignInWithGitHub`, `PRHubSelfHosted` and `PRHubSamples`. A flag is on for
    /// `YES` (or a true boolean); a missing one is off. `overrides` wins where it has the key.
    init(info: [String: Any], overrides: UserDefaults? = nil) {
        func flag(_ key: String) -> Bool {
            if let override = overrides?.object(forKey: key) {
                return Self.isOn(override)
            }
            return Self.isOn(info[key])
        }
        let host = (info["PRHubHostedHost"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        hostedURL = host.isEmpty || host.contains("$(") ? nil : URL(string: "https://\(host)")
        signInWithGitHub = flag("PRHubSignInWithGitHub") && hostedURL != nil
        selfHosted = flag("PRHubSelfHosted")
        samples = flag("PRHubSamples")
    }

    private static func isOn(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let word as String: ["yes", "true", "1"].contains(word.lowercased())
        default: false
        }
    }

    /// The launch arguments' domain, in a Debug build only.
    private static var debugOverrides: UserDefaults? {
        #if DEBUG
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return arguments.isEmpty ? nil : UserDefaults.standard
        #else
        nil
        #endif
    }
}
