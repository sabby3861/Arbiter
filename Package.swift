// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Arbiter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Arbiter",
            targets: ["Arbiter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.21.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "Arbiter",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXLLM", package: "mlx-swift-examples", condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "Sources/Arbiter"),
        .testTarget(
            name: "ArbiterTests",
            dependencies: ["Arbiter"],
            path: "Tests/ArbiterTests"),
    ]
)
