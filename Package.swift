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
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.21.0"),
    ],
    targets: [
        .target(
            name: "SwiftAI",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXLLM", package: "mlx-swift-examples", condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "Sources/SwiftAI"),
        .testTarget(
            name: "SwiftAITests",
            dependencies: ["SwiftAI"],
            path: "Tests/SwiftAITests"),
    ]
)
