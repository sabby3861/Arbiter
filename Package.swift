// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwiftAI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SwiftAI",
            targets: ["SwiftAI"]),
    ],
    targets: [
        .target(
            name: "SwiftAI",
            path: "Sources/SwiftAI"),
        .testTarget(
            name: "SwiftAITests",
            dependencies: ["SwiftAI"],
            path: "Tests/SwiftAITests"),
    ]
)
