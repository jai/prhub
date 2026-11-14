import Foundation

/// Why pairing stopped, in words for the onboarding screen (docs/api.md, "Pairing").
enum PairingError: Error, Equatable, Sendable {
    /// `400 validation_error`: the Worker did not take the code's shape.
    case codeMalformed
    /// `401 pairing_code_invalid`: unknown, used or expired; one answer for all three.
    case codeRefused
    /// `401 unauthorized`: the Worker refused this app's device secret.
    case secretRefused
    /// `404`: a Worker without the pairing route.
    case pairingUnsupported
    /// The code was minted with `--app`: for an app, not a phone.
    case appCode
    case unreachable(host: String)
    case server(status: Int)
    case unreadable
    /// The device secret or the Worker URL could not be read or saved: a locked phone, mostly.
    case keychain

    /// The code is spent or wrong: only a new one helps.
    var needsNewCode: Bool {
        switch self {
        case .codeMalformed, .codeRefused, .appCode: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .codeMalformed:
            "The Worker didn't accept that code. A code is 8 letters and digits, like 7KQ2-M9XA."
        case .codeRefused:
            "That code has expired, was already used, or is wrong. Run npm run pair on your Worker for a new one."
        case .secretRefused:
            "The Worker refused this \(AppIdentity.deviceName)'s key. Try again; if it keeps happening, reinstall "
                + "PRHub."
        case .pairingUnsupported:
            "This Worker can't pair phones yet. Update it from github.com/jai/prhub and try again."
        case .appCode:
            "That code is for an app, not a phone. Run npm run pair without --app for a phone code."
        case .unreachable(let host):
            "Couldn't reach \(host). Check the address and your internet connection."
        case .server:
            "The Worker had a problem on its side. Try again in a minute; if it keeps happening, check its logs."
        case .unreadable:
            "The Worker's answer didn't make sense. Check that the address is your pr-worker."
        case .keychain:
            AppIdentity.keychainProblem
        }
    }

    /// What `POST /device/pair` failed with, as the onboarding screen says it.
    init(pairing error: any Error, host: String) {
        guard let error = error as? PairingClient.Failure else {
            self = .keychain // the secret could not be read: the only throw before the request is sent
            return
        }
        switch error {
        case .server("validation_error", 400):
            self = .codeMalformed
        case .server("pairing_code_invalid", 401):
            self = .codeRefused
        case .server(_, 401):
            self = .secretRefused
        case .server(_, 404), .server(_, 405):
            self = .pairingUnsupported
        case .server(_, let status):
            self = .server(status: status)
        case .transport:
            self = .unreachable(host: host)
        case .decoding:
            self = .unreadable
        }
    }
}

/// The first run, after a setup link has been read: `POST /device/pair` at the link's Worker, then the Worker saved.
/// A pr-worker admits a paired secret at once, so there is nothing to wait for. `POST /device/pair` is never retried:
/// a code is single use.
struct DevicePairing: Sendable {
    /// `POST /device/pair` at this Worker with this code.
    var pair: @Sendable (_ worker: URL, _ code: String) async throws -> PairingClient.PairResponse
    /// Keeps the Worker URL: from here on every request goes there.
    var save: @Sendable (URL) throws -> Void

    enum Step: Equatable, Sendable {
        case pairing
        /// Sign in with GitHub, from the sheet to the first config.
        case signingIn
    }

    func run(_ link: SetupLink) async throws(PairingError) {
        let host = link.worker.host() ?? link.worker.absoluteString
        let response: PairingClient.PairResponse
        do {
            response = try await pair(link.worker, link.code)
        } catch {
            throw PairingError(pairing: error, host: host)
        }
        guard response.role == .device else {
            throw .appCode
        }
        do {
            try save(link.worker)
        } catch {
            throw .keychain
        }
    }
}
