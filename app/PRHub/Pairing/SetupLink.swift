import Foundation

/// What a PRHub pr-worker's `npm run pair` prints (docs/api.md, "The setup link"):
/// `prhub://setup?worker=<percent-encoded https URL>&code=<8 characters>`, read from a scanned QR code, a pasted
/// link, an opened link, or the two values typed in. Only a valid pair can be made: `worker` is `https://<host>[:port]`
/// with nothing after it, and `code` is the 8 Crockford base32 characters the Worker matches.
struct SetupLink: Equatable, Sendable {
    let worker: URL
    let code: String

    /// The Worker's alphabet: `0-9` and `A-Z` without `I`, `L`, `O` and `U`.
    /// PRHub's URL scheme (project.yml, `CFBundleURLTypes`).
    static let scheme = "prhub"

    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 8

    enum Failure: Error, Equatable {
        case notASetupLink
        case badWorker
        case badCode

        /// For the onboarding screen.
        var message: String {
            switch self {
            case .notASetupLink:
                "That isn't a setup link. A setup link starts with prhub://setup."
            case .badWorker:
                "The Worker address must be an https:// address with nothing after the host, like "
                    + "https://pr-review.example.workers.dev."
            case .badCode:
                "The code must be 8 letters and digits, like 7KQ2-M9XA."
            }
        }
    }

    /// A link as scanned, pasted or opened. A link has no spaces, so any whitespace — a paste that wrapped — is
    /// dropped first: left in, `URLComponents` would encode the whole link again and its values would stay encoded.
    static func parse(_ text: String) throws(Failure) -> SetupLink {
        let compact = text.filter { !$0.isWhitespace }
        guard let components = URLComponents(string: compact),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "setup",
              components.path.isEmpty || components.path == "/"
        else {
            throw .notASetupLink
        }
        let items = components.queryItems ?? []
        guard let worker = items.first(where: { $0.name == "worker" })?.value else {
            throw .badWorker
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw .badCode
        }
        return try SetupLink(worker: worker, code: code)
    }

    /// The two values typed in. A Worker address without a scheme is taken as `https://`.
    init(worker: String, code: String) throws(Failure) {
        self.worker = try Self.workerURL(worker)
        self.code = try Self.normalisedCode(code)
    }

    /// `https://<host>[:port]`, lowercased, without a trailing slash; anything else is refused.
    static func workerURL(_ text: String) throws(Failure) -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil
        else {
            throw .badWorker
        }
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host
        clean.port = components.port
        guard let url = clean.url else {
            throw .badWorker
        }
        return url
    }

    /// Without regard to case, spaces or hyphens, as the Worker matches it: `7kq2-m9xa` is `7KQ2M9XA`.
    static func normalisedCode(_ text: String) throws(Failure) -> String {
        let code = text.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard code.count == codeLength, code.allSatisfy(alphabet.contains) else {
            throw .badCode
        }
        return code
    }

    /// As people are shown it: `7KQ2-M9XA`.
    var displayCode: String {
        String(code.prefix(4)) + "-" + String(code.suffix(4))
    }
}
