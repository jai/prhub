// PRHub's Xcode Cloud, through the App Store Connect API. Run by release/ship.sh and release/next-build.sh with the API
// key at <key.p8>, and with ASC_KEY_ID, ASC_ISSUER_ID and APP_BUNDLE_ID in the environment:
//   swift release/xcode-cloud.swift <key.p8> runs
//     one line per recent build of the PRHub Release workflow, newest first:
//     <commit sha> <build number> <executionProgress> <completionStatus>
//     (PENDING / RUNNING / COMPLETE; SUCCEEDED, FAILED, ERRORED, CANCELED or SKIPPED once complete, else "-")
//   swift release/xcode-cloud.swift <key.p8> latest
//     the product's highest build number, any workflow, or 0. Every workflow of the product shares one sequence.
//   swift release/xcode-cloud.swift <key.p8> create-workflow
//     creates the PRHub Release workflow, turns it on when it is off, or says it exists: on a push to main that changes app/project.yml,
//     archive the PRHub scheme for App Store Connect, clean, on the latest Xcode release. TestFlight post-actions
//     are not in the API: add them in Xcode (AGENTS.md, "Releases").
// Exits 3, saying why on stderr, when the app has no Xcode Cloud product (`create-workflow`, `latest`) or no enabled
// PRHub Release workflow (`runs`): then nothing will build a release, and ship.sh ships locally.
// The build number is the one TestFlight shows (app/ci_scripts/ci_post_clone.sh). Tokens are signed as in
// release/testflight.swift.
import CryptoKit
import Foundation

let workflowName = "PRHub Release"  // CI_WORKFLOW in app/ci_scripts/release.sh
let containerFilePath = "app/PRHub.xcodeproj"

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

func required(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fail("\(name) is not set: run through release/ship.sh", status: 2)
    }
    return value
}

let keyID = required("ASC_KEY_ID")
let issuerID = required("ASC_ISSUER_ID")
let bundleID = required("APP_BUNDLE_ID")
let arguments = CommandLine.arguments
guard arguments.count == 3, ["runs", "latest", "create-workflow"].contains(arguments[2]) else {
    fail("usage: xcode-cloud <key.p8> runs|latest|create-workflow", status: 2)
}
let key: P256.Signing.PrivateKey
do {
    key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: arguments[1], encoding: .utf8))
} catch {
    fail("cannot read the App Store Connect key at \(arguments[1]): \(error)")
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func token() throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
    let claims = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 600),"aud":"appstoreconnect-v1"}"#
    let signed = base64URL(Data(header.utf8)) + "." + base64URL(Data(claims.utf8))
    return signed + "." + base64URL(try key.signature(for: Data(signed.utf8)).rawRepresentation)
}

/// The response's `data`, as loose JSON: build runs and workflows carry numbers and nested objects.
func request(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws
    -> Any?
{
    var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!
    if !query.isEmpty {
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let json {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        fail("\(method) \(path): HTTP \(status) \(String(decoding: data, as: UTF8.self))")
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"]
}

func list(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
    try await request("GET", path, query: query) as? [[String: Any]] ?? []
}

func attributes(_ resource: [String: Any]) -> [String: Any] {
    resource["attributes"] as? [String: Any] ?? [:]
}

func product() async throws -> [String: Any] {
    let apps = try await list("apps", ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])
    guard let app = apps.first?["id"] as? String else { fail("App Store Connect has no app \(bundleID)") }
    let products = try await list("ciProducts", [
        "filter[app]": app, "fields[ciProducts]": "name,primaryRepositories", "include": "primaryRepositories",
    ])
    guard let product = products.first else { fail("no Xcode Cloud product for \(bundleID)", status: 3) }
    return product
}

func releaseWorkflow(product: String) async throws -> [String: Any]? {
    try await list("ciProducts/\(product)/workflows", ["fields[ciWorkflows]": "name,isEnabled", "limit": "200"])
        .first { attributes($0)["name"] as? String == workflowName }
}

/// `<commit sha> <number> <progress> <status>` lines, newest first.
func printRuns(_ path: String) async throws {
    let runs = try await list(path, [
        "limit": "50", "sort": "-number",
        "fields[ciBuildRuns]": "number,executionProgress,completionStatus,sourceCommit",
    ])
    for run in runs {
        let fields = attributes(run)
        guard let number = fields["number"] as? Int else { continue }
        let commit = (fields["sourceCommit"] as? [String: Any])?["commitSha"] as? String ?? "-"
        let progress = fields["executionProgress"] as? String ?? "-"
        let status = fields["completionStatus"] as? String ?? "-"
        print("\(commit) \(number) \(progress) \(status)")
    }
}

func latestNumber(product: String) async throws -> Int {
    let newest = try await list(
        "ciProducts/\(product)/buildRuns", ["limit": "1", "sort": "-number", "fields[ciBuildRuns]": "number"])
    return newest.first.flatMap { attributes($0)["number"] as? Int } ?? 0
}

/// The Xcode release Xcode Cloud calls "Latest Release", and the macOS it runs on, so the workflow follows new Xcodes.
func latestRelease() async throws -> (xcode: String, macOS: String) {
    let xcodes = try await list("ciXcodeVersions", ["fields[ciXcodeVersions]": "name", "limit": "200"])
    guard let xcode = xcodes.first(where: { attributes($0)["name"] as? String == "Latest Release" })?["id"] as? String
    else { fail("Xcode Cloud lists no Xcode named Latest Release") }
    let systems = try await list("ciXcodeVersions/\(xcode)/macOsVersions", ["fields[ciMacOsVersions]": "name"])
    guard let macOS = systems.first(where: { attributes($0)["name"] as? String == "Latest Release" })?["id"] as? String
    else { fail("Xcode Cloud lists no macOS named Latest Release for its latest Xcode") }
    return (xcode, macOS)
}

func createReleaseWorkflow(product: [String: Any]) async throws {
    let productID = product["id"] as! String
    if let existing = try await releaseWorkflow(product: productID), let id = existing["id"] as? String {
        guard attributes(existing)["isEnabled"] as? Bool != true else {
            print("\(workflowName) already exists: workflow \(id)")
            return
        }
        _ = try await request("PATCH", "ciWorkflows/\(id)", json: [
            "data": ["type": "ciWorkflows", "id": id, "attributes": ["isEnabled": true]],
        ])
        print("\(workflowName) was off, now on: workflow \(id)")
        return
    }
    let repositories = (product["relationships"] as? [String: Any])?["primaryRepositories"] as? [String: Any]
    guard let repository = (repositories?["data"] as? [[String: Any]])?.first?["id"] as? String else {
        fail("the Xcode Cloud product has no primary repository")
    }
    let (xcode, macOS) = try await latestRelease()
    let created = try await request("POST", "ciWorkflows", json: [
        "data": [
            "type": "ciWorkflows",
            "attributes": [
                "name": workflowName,
                "description": "A chore(release): PRHub build N commit on main: archive and hand to TestFlight.",
                "isEnabled": true,
                "isLockedForEditing": false,
                "clean": true,
                "containerFilePath": containerFilePath,
                "branchStartCondition": [
                    "source": ["isAllMatch": false, "patterns": [["pattern": "main", "isPrefix": false]]],
                    "filesAndFoldersRule": [
                        "mode": "START_IF_ANY_FILE_MATCHES",
                        "matchers": [["directory": "app", "fileName": "project.yml"]],
                    ],
                    "autoCancel": false,
                ],
                "actions": [[
                    "name": "Archive - iOS",
                    "actionType": "ARCHIVE",
                    "scheme": "PRHub",
                    "platform": "IOS",
                    "buildDistributionAudience": "APP_STORE_ELIGIBLE",
                    "isRequiredToPass": true,
                ]],
            ],
            "relationships": [
                "product": ["data": ["type": "ciProducts", "id": productID]],
                "repository": ["data": ["type": "scmRepositories", "id": repository]],
                "xcodeVersion": ["data": ["type": "ciXcodeVersions", "id": xcode]],
                "macOsVersion": ["data": ["type": "ciMacOsVersions", "id": macOS]],
            ],
        ],
    ])
    print("\(workflowName) created: workflow \((created as? [String: Any])?["id"] as? String ?? "?")")
}

setvbuf(stdout, nil, _IOLBF, 0)
do {
    let found = try await product()
    let productID = found["id"] as! String
    switch arguments[2] {
    case "runs":
        guard let workflow = try await releaseWorkflow(product: productID),
            attributes(workflow)["isEnabled"] as? Bool == true, let workflowID = workflow["id"] as? String
        else { fail("no enabled Xcode Cloud workflow named \(workflowName) for \(bundleID)", status: 3) }
        try await printRuns("ciWorkflows/\(workflowID)/buildRuns")
    case "latest":
        print(try await latestNumber(product: productID))
    default:
        try await createReleaseWorkflow(product: found)
    }
} catch {
    fail("\(error)")
}
