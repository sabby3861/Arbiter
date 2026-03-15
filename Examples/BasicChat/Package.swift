// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BasicChat",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "BasicChat",
            dependencies: [
                .product(name: "Arbiter", package: "Arbiter"),
            ],
            path: "Sources"
        ),
    ]
)
