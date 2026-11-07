// A TestFlight build of PRHub in App Store Connect, through its API. Run by release/ship.sh with the App Store Connect
// API key at <key.p8>, and with ASC_KEY_ID, ASC_ISSUER_ID and APP_BUNDLE_ID in the environment:
//   swift release/testflight.swift <key.p8> state <version> <build>
//     prints the build's processingState (PROCESSING, VALID, FAILED or INVALID), or nothing when there is no such build
//   swift release/testflight.swift <key.p8> what-to-test <version> <build> <text>
//     waits up to 30 minutes for the build to appear, then sets its en-US What to Test to <text>, cut to Apple's
//     4000-byte limit
//   swift release/testflight.swift <key.p8> latest
//     prints the app's highest build number in App Store Connect, any version, or 0 when it has none
//   swift release/testflight.swift <key.p8> add-to-group <version> <build> <beta group id>
//     adds the build to a TestFlight group (an external one for PRHub's public link)
//   swift release/testflight.swift <key.p8> submit <version> <build>
//     submits the build for Beta App Review, unless another build of the app is still waiting for or in review:
//     Apple reviews one at a time, and the build that passes opens the public link for the builds after it
// A build takes What to Test while it is still processing (fastlane sets it then); a refusal while it is processing
// is tried again every 30 seconds until the 30 minutes are up, a refusal once it is processed is final. Every request
// carries a fresh ES256 token signed with the key by CryptoKit, so there is no JWT library.
import CryptoKit
import Foundation

func required(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        FileHandle.standardError.write(Data("\(name) is not set: run through release/ship.sh\n".utf8))
        exit(2)
    }
    return value
}

let keyID = required("ASC_KEY_ID")
let issuerID = required("ASC_ISSUER_ID")
let bundleID = required("APP_BUNDLE_ID")
let locale = "en-US"
let usage = """
    usage: testflight-build <key.p8> state <version> <build>
           testflight-build <key.p8> what-to-test <version> <build> <text>
           testflight-build <key.p8> latest
           testflight-build <key.p8> add-to-group <version> <build> <beta group id>
           testflight-build <key.p8> submit <version> <build>
    """

struct Document<Body: Decodable>: Decodable {
    let data: Body
}

/// A JSON:API resource fetched with only string attributes.
struct Resource: Decodable {
    let id: String
    let attributes: [String: String?]

    subscript(name: String) -> String? { attributes[name] ?? nil }
}

struct RequestFailed: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail(usage) }
let command = arguments[2]
let version = arguments.count > 3 ? arguments[3] : ""
let build = arguments.count > 4 ? arguments[4] : ""
let key: P256.Signing.PrivateKey
do {
    key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: arguments[1], encoding: .utf8))
} catch {
    fail("cannot read the App Store Connect key at \(arguments[1]): \(error)")
}

/// A token for one request. App Store Connect refuses one that lives longer than 20 minutes.
func token() throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
    let claims = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 600),"aud":"appstoreconnect-v1"}"#
    let signed = base64URL(Data(header.utf8)) + "." + base64URL(Data(claims.utf8))
    return signed + "." + base64URL(try key.signature(for: Data(signed.utf8)).rawRepresentation)
}

/// A request whose answer has no body to read (204), or one that is not needed.
func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws {
    _ = try await request(method, path, query: query, json: json)
}

func call<Body: Decodable>(
    _ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil
) async throws -> Body {
    try JSONDecoder().decode(Document<Body>.self, from: try await request(method, path, query: query, json: json)).data
}

func request(
    _ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil
) async throws -> Data {
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
        throw RequestFailed(description: "\(method) \(path): HTTP \(status) \(String(decoding: data, as: UTF8.self))")
    }
    return data
}

func findApp() async throws -> String {
    let apps: [Resource] = try await call(
        "GET", "apps", query: ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])
    guard let app = apps.first(where: { $0["bundleId"] == bundleID }) else {
        throw RequestFailed(description: "App Store Connect has no app \(bundleID)")
    }
    return app.id
}

/// The build, or nil while App Store Connect has none with this version and number.
func findBuild(app: String) async throws -> Resource? {
    let builds: [Resource] = try await call("GET", "builds", query: [
        "filter[app]": app,
        "filter[preReleaseVersion.version]": version,
        "filter[version]": build,
        "fields[builds]": "processingState",
    ])
    return builds.first
}

/// Updates the build's en-US localization, or creates it, and returns what App Store Connect now holds.
func setWhatToTest(_ text: String, buildID: String) async throws -> Resource {
    let localizations: [Resource] = try await call(
        "GET", "builds/\(buildID)/betaBuildLocalizations", query: ["fields[betaBuildLocalizations]": "locale,whatsNew"])
    if let localization = localizations.first(where: { $0["locale"] == locale }) {
        return try await call("PATCH", "betaBuildLocalizations/\(localization.id)", json: [
            "data": ["type": "betaBuildLocalizations", "id": localization.id, "attributes": ["whatsNew": text]],
        ])
    }
    return try await call("POST", "betaBuildLocalizations", json: [
        "data": [
            "type": "betaBuildLocalizations",
            "attributes": ["locale": locale, "whatsNew": text],
            "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
        ],
    ])
}

func waitAndSetWhatToTest(_ text: String, app: String) async throws {
    let deadline = Date().addingTimeInterval(30 * 60)
    while true {
        if let found = try await findBuild(app: app) {
            let state = found["processingState"] ?? "UNKNOWN"
            guard state == "PROCESSING" || state == "VALID" else {
                fail("build \(build) is \(state) in App Store Connect: What to Test not set")
            }
            do {
                let localization = try await setWhatToTest(text, buildID: found.id)
                let length = localization["whatsNew"]?.count ?? 0
                print("build \(build): What to Test set (\(localization["locale"] ?? locale), \(length) characters)")
                return
            } catch let error where state == "PROCESSING" && Date() < deadline {
                print("build \(build) is processing and refused What to Test, trying again in 30 s: \(error)")
            }
        } else if Date() < deadline {
            print("waiting for build \(build) to appear in App Store Connect")
        } else {
            fail("""
                build \(build) has not appeared in App Store Connect in 30 minutes. Once it has, run \
                make -C ios testflight-release again: it uploads nothing and sets What to Test.
                """)
        }
        try await Task.sleep(for: .seconds(30))
    }
}

/// Every build of the app, any version, newest upload first.
func allBuilds(app: String) async throws -> [Resource] {
    try await call("GET", "builds", query: [
        "filter[app]": app, "sort": "-uploadedDate", "limit": "200", "fields[builds]": "version,processingState",
    ])
}

func existingBuild(app: String) async throws -> Resource {
    guard let found = try await findBuild(app: app) else {
        fail("App Store Connect has no build \(build) of version \(version)")
    }
    return found
}

/// Submits `buildID` for Beta App Review unless a build is already waiting for or in review, and says which it did.
func submitForReview(buildID: String, app: String) async throws {
    for other in try await allBuilds(app: app) {
        let submission: Resource? = try await call(
            "GET", "builds/\(other.id)/betaAppReviewSubmission",
            query: ["fields[betaAppReviewSubmissions]": "betaReviewState"])
        guard let submission else {
            continue
        }
        let state = submission["betaReviewState"] ?? "UNKNOWN"
        if other.id == buildID {
            print("build \(build) is already submitted for Beta App Review (\(state))")
            return
        }
        if state == "WAITING_FOR_REVIEW" || state == "IN_REVIEW" {
            print("build \(build) not submitted: build \(other["version"] ?? "?") is \(state); submit this one once it is approved")
            return
        }
    }
    let submission: Resource = try await call("POST", "betaAppReviewSubmissions", json: [
        "data": [
            "type": "betaAppReviewSubmissions",
            "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
        ],
    ])
    print("build \(build) submitted for Beta App Review (\(submission["betaReviewState"] ?? "submitted"))")
}

setvbuf(stdout, nil, _IOLBF, 0)
do {
    let app = try await findApp()
    switch command {
    case "state" where arguments.count == 5:
        if let found = try await findBuild(app: app) {
            print(found["processingState"] ?? "UNKNOWN")
        }
    case "what-to-test" where arguments.count == 6:
        var text = arguments[5]
        while text.utf8.count > 4000 {
            text.removeLast()
        }
        try await waitAndSetWhatToTest(text, app: app)
    case "latest" where arguments.count == 3:
        print(try await allBuilds(app: app).compactMap { $0["version"].flatMap { Int($0) } }.max() ?? 0)
    case "add-to-group" where arguments.count == 6:
        let found = try await existingBuild(app: app)
        try await send("POST", "betaGroups/\(arguments[5])/relationships/builds", json: [
            "data": [["type": "builds", "id": found.id]],
        ])
        print("build \(build) added to beta group \(arguments[5])")
    case "submit" where arguments.count == 5:
        try await submitForReview(buildID: try await existingBuild(app: app).id, app: app)
    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
