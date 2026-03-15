// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OnDeviceOnly",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "OnDeviceOnly",
            dependencies: [
                .product(name: "Arbiter", package: "Arbiter"),
            ],
            path: "Sources"
        ),
    ]
)
