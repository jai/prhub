import Foundation

/// The inputs for the checks against a deployed self-hosted Worker, run by hand on a test install of their own. Set on
/// the test runner: `PRHUB_E2E_DEVICE_OWNED=YES`, `PRHUB_E2E_WORKER` (HTTPS origin), `PRHUB_E2E_LOGIN`,
/// `PRHUB_E2E_REPO` (`owner/repo`), `PRHUB_E2E_PR`, `PRHUB_E2E_TITLE`, and for pairing a fresh `PRHUB_E2E_SETUP` link.
/// `PRHubE2EPairingTests.xctestplan` pairs an unpaired install; `PRHubE2ETests.xctestplan` then runs Ask and the
/// notification check on it. Missing inputs fail the test.
struct E2ETarget {
    let worker: URL
    let login: String
    let repo: String
    let number: Int
    let title: String

    var reference: String {
        "\(repo)#\(number)"
    }

    static func load(from environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard environment["PRHUB_E2E_DEVICE_OWNED"] == "YES" else {
            throw E2EFailure("Use an explicitly dedicated test install; set PRHUB_E2E_DEVICE_OWNED=YES.")
        }
        let worker = try origin(required("PRHUB_E2E_WORKER", in: environment))
        let login = try required("PRHUB_E2E_LOGIN", in: environment)
        let repo = try required("PRHUB_E2E_REPO", in: environment)
        guard login.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              let number = try Int(required("PRHUB_E2E_PR", in: environment)), number > 0
        else {
            throw E2EFailure("Provide a GitHub login, owner/repo and positive PR number for the dedicated fixture.")
        }
        return try Self(worker: worker, login: login, repo: repo, number: number,
                        title: required("PRHUB_E2E_TITLE", in: environment))
    }

    func setupLink(from environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let raw = try Self.required("PRHUB_E2E_SETUP", in: environment)
        guard let parts = URLComponents(string: raw), parts.scheme == "prhub", parts.host == "setup",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty,
              parts.fragment == nil, let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "worker" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              let origin = items.first(where: { $0.name == "worker" })?.value,
              try Self.origin(origin) == worker,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: "^[0-9A-HJKMNP-TV-Z]{8}$", options: .regularExpression) != nil,
              let link = parts.url
        else {
            throw E2EFailure("PRHUB_E2E_SETUP must be a fresh setup link for exactly PRHUB_E2E_WORKER.")
        }
        return link
    }

    var handoff: URL {
        var parts = URLComponents()
        parts.scheme = "prhub-pr"
        parts.host = "open"
        parts.queryItems = [.init(name: "url", value: "https://github.com/\(repo)/pull/\(number)")]
        return parts.url!
    }

    private static func required(_ key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw E2EFailure("Missing \(key). See E2ETarget for the inputs.")
        }
        return value
    }

    private static func origin(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil
        else {
            throw E2EFailure("PRHUB_E2E_WORKER must be an HTTPS origin without credentials, a path or query.")
        }
        parts.host = parts.host?.lowercased()
        parts.port = nil
        parts.path = ""
        return parts.url!
    }
}

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
