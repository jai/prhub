// swift-tools-version: 6.2
import PackageDescription

// PRKit: PRHub's PR screens as a package (PRKit/README.md). PRHub (app/) is `PRKitRoot` over a host of its own; other
// apps add this repo by URL and embed the same screens as one tab.
let package = Package(
    name: "PRKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Foundation alone, safe in an app extension: links, refs, the rows, the pr-worker client and what it sends.
        .library(name: "PRKitCore", targets: ["PRKitCore"]),
        // The type, palette and motion the PR screens draw with, for the rest of a host app too.
        .library(name: "PRKitDesign", targets: ["PRKitDesign"]),
        // The screens, their models and the host API.
        .library(name: "PRKit", targets: ["PRKit"]),
        // Feature requests from inside an app, each a conversation with an agent that changes it: FeedbackKit
        // (jai/feedbackkit) over PRKit's Worker client.
        .library(name: "FeatureKit", targets: ["FeatureKit"]),
    ],
    dependencies: [
        // The chat with a coding agent: Ask AI's, and every chat a host draws (its README.md).
        .package(url: "https://github.com/jai/agentchatkit", from: "0.1.0"),
        // Feedback from inside the app (its README.md); FeatureKit is it over PRKit's Worker client.
        .package(url: "https://github.com/jai/feedbackkit", from: "0.1.0"),
    ],
    targets: [
        // The transport and the deadline, package-only: a host's own network types keep their names.
        .target(name: "PRKitNetwork", path: "PRKit/Sources/PRKitNetwork"),
        .target(
            name: "PRKitCore", dependencies: ["PRKitNetwork", .product(name: "AgentChatCore", package: "agentchatkit")],
            path: "PRKit/Sources/PRKitCore"
        ),
        .target(name: "PRKitDesign", path: "PRKit/Sources/PRKitDesign"),
        // The diff's open-licence fonts, each with its OFL, registered at run time (DiffFont.swift).
        .target(
            name: "PRKit",
            dependencies: [
                "PRKitCore", "PRKitDesign", "PRKitNetwork", .product(name: "AgentChatKit", package: "agentchatkit"),
            ],
            path: "PRKit/Sources/PRKit",
            resources: [.copy("Resources/Fonts")]
        ),
        .target(
            name: "FeatureKit", dependencies: ["PRKitCore", .product(name: "FeedbackKit", package: "feedbackkit")],
            path: "PRKit/Sources/FeatureKit"
        ),
        .testTarget(name: "PRKitTests", dependencies: ["PRKit", "PRKitNetwork"], path: "PRKit/Tests/PRKitTests"),
    ]
)
