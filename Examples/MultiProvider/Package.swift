// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MultiProvider",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "MultiProvider",
            dependencies: [
                .product(name: "SwiftAI", package: "SwiftAI"),
            ],
            path: "Sources"
        ),
    ]
)
