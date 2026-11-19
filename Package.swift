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
        .library(name: "PRHubCore", targets: ["PRHubCore"]),
    ],
    dependencies: [
        // Every request the PR screens make goes through the host's transport from it (its README.md).
        .package(url: "https://github.com/jai/durable-networking", from: "0.4.0"),
        // The chat with a coding agent: Ask AI's, and every chat a host draws (its README.md).
        .package(url: "https://github.com/jai/agentchatkit", from: "0.5.0"),
        // Feedback from inside the app (its README.md); FeatureKit is it over PRKit's Worker client.
        .package(url: "https://github.com/jai/feedbackkit", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "PRContractFixtures",
            path: "PRKit/Tests/PRContractFixtures",
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "PRKitCore",
            dependencies: [
                .product(name: "DurableNetworking", package: "durable-networking"),
                .product(name: "AgentChatCore", package: "agentchatkit"),
            ],
            path: "PRKit/Sources/PRKitCore"
        ),
        .target(name: "PRKitDesign", path: "PRKit/Sources/PRKitDesign"),
        // The diff's open-licence fonts, each with its OFL, registered at run time (DiffFont.swift).
        .target(
            name: "PRKit",
            dependencies: [
                "PRKitCore", "PRKitDesign", .product(name: "AgentChatKit", package: "agentchatkit"),
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "PRKit/Sources/PRKit",
            resources: [.copy("Resources/Fonts")]
        ),
        .target(
            name: "FeatureKit",
            dependencies: [
                "PRKitCore", .product(name: "FeedbackKit", package: "feedbackkit"),
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "PRKit/Sources/FeatureKit"
        ),
        // App behavior shared by PRHub and its host-free test targets.
        .target(
            name: "PRHubCore",
            dependencies: [
                "PRKit", "PRKitCore", "FeatureKit", .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "app/PRHubCore"
        ),
        .target(name: "PRHubTestSupport", path: "app/PRHubTests/Support"),
        // The PR screens' stores in memory, a test clock and a transport no test should reach: for PRKit's and the app's
        // tests alike.
        .target(
            name: "PRKitTestSupport",
            dependencies: ["PRKit", "PRKitCore", .product(name: "DurableNetworking", package: "durable-networking")],
            path: "PRKit/Tests/PRKitTestSupport"
        ),
        .testTarget(
            name: "PRHubUnitTests",
            dependencies: [
                "PRHubTestSupport", "PRKitTestSupport", "PRHubCore", "PRKit", "PRKitCore",
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "app/PRHubTests/Unit"
        ),
        .testTarget(
            name: "PRHubIntegrationTests",
            dependencies: [
                "PRHubTestSupport", "PRContractFixtures", "PRHubCore", "PRKit", "PRKitCore",
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "app/PRHubTests/Integration"
        ),
        .testTarget(
            name: "PRKitUnitTests",
            dependencies: [
                "PRKit", "PRKitCore", "FeatureKit", "PRKitTestSupport",
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "PRKit/Tests/PRKitTests/Unit"
        ),
        // Local storage, bundled resources and the diff's real fonts. PRKitRenderingTests' font and AppKit checks run here
        // on the Mac; the iOS rendering target (app/project.yml) compiles the same folder with its UIKit checks.
        .testTarget(
            name: "PRKitIntegrationTests",
            dependencies: [
                "PRContractFixtures", "PRKit", "PRKitDesign", "PRKitTestSupport", "FeatureKit",
                .product(name: "DurableNetworking", package: "durable-networking"),
            ],
            path: "PRKit/Tests",
            exclude: ["PRContractFixtures", "PRKitTestSupport", "PRKitTests/Unit"],
            sources: ["PRKitTests/Integration", "PRKitRenderingTests"]
        ),
    ]
)
