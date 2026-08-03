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
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "Arbiter",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "Sources/Arbiter"),
        .testTarget(
            name: "ArbiterTests",
            dependencies: ["Arbiter"],
            path: "Tests/ArbiterTests"),
    ]
)
